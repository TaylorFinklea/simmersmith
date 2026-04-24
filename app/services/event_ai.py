"""AI event menu generation.

Given an Event with its attendee list, ask the AI to design a 4–6 dish
menu that handles mixed dietary constraints intelligently: the core
menu is designed for the majority, then each constrained guest is
checked to ensure at least one dish per meal role works for them.
"""
from __future__ import annotations

import json
import logging
from typing import Any

from pydantic import BaseModel, ValidationError
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import Event, Guest
from app.services.ai import (
    SUPPORTED_DIRECT_PROVIDERS,
    direct_provider_availability,
    resolve_direct_model,
)
from app.services.assistant_ai import (
    AssistantExecutionTarget,
    extract_json_object,
    run_direct_provider,
)
from app.services.events import replace_event_meals

logger = logging.getLogger(__name__)


DEFAULT_ROLES = ("starter", "main", "side", "side", "dessert")


class _AIIngredient(BaseModel):
    ingredient_name: str
    quantity: float | None = None
    unit: str = ""
    prep: str = ""
    category: str = ""
    notes: str = ""


class _AIMeal(BaseModel):
    role: str
    recipe_name: str
    servings: float | None = None
    notes: str = ""
    # List of guest names this dish is explicitly compatible with. Empty
    # = works for everyone. The prompt asks the AI to populate this when
    # a dish is tailored to a specific constraint.
    compatible_guests: list[str] = []
    ingredients: list[_AIIngredient] = []


class _AIResponse(BaseModel):
    menu: list[_AIMeal]
    coverage_summary: str = ""


def _resolve_target(settings: Settings, user_settings: dict[str, str]) -> AssistantExecutionTarget:
    preferred = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    candidates: list[str] = []
    if preferred in SUPPORTED_DIRECT_PROVIDERS:
        candidates.append(preferred)
    for name in SUPPORTED_DIRECT_PROVIDERS:
        if name not in candidates:
            candidates.append(name)
    for name in candidates:
        available, source = direct_provider_availability(name, settings=settings, user_settings=user_settings)
        if available:
            model = resolve_direct_model(name, settings=settings, user_settings=user_settings)
            return AssistantExecutionTarget(
                provider_kind="direct",
                source=source,
                provider_name=name,
                model=model,
            )
    raise RuntimeError("No direct AI provider is configured for event menu generation.")


def _describe_guests(attendees: list[tuple[Guest, int]]) -> tuple[str, dict[str, str]]:
    """Returns a prompt block + a name→guest_id lookup for resolving
    constraint_coverage back to guest ids."""
    if not attendees:
        return "(no specific guests listed — design for a general audience)", {}
    lines: list[str] = []
    lookup: dict[str, str] = {}
    for guest, plus_ones in attendees:
        lookup[guest.name.strip().lower()] = guest.id
        parts = [f"- {guest.name}"]
        if plus_ones > 0:
            parts.append(f"(+{plus_ones} more in their party)")
        if guest.relationship_label:
            parts.append(f"({guest.relationship_label})")
        if guest.allergies.strip():
            parts.append(f"ALLERGIES: {guest.allergies.strip()}")
        if guest.dietary_notes.strip():
            parts.append(f"notes: {guest.dietary_notes.strip()}")
        lines.append(" ".join(parts))
    return "\n".join(lines), lookup


def _build_prompt(
    *,
    event: Event,
    attendees: list[tuple[Guest, int]],
    roles: list[str],
    user_prompt: str,
) -> str:
    guest_block, _ = _describe_guests(attendees)
    role_spec = ", ".join(roles) if roles else "dealer's choice"
    date_line = f"Date: {event.event_date.isoformat()}" if event.event_date else "Date: TBD"
    notes_line = f"\nHost notes: {event.notes.strip()}" if event.notes.strip() else ""
    extra = f"\nUser request: {user_prompt.strip()}" if user_prompt.strip() else ""
    schema = (
        '{\n'
        '  "menu": [\n'
        '    {\n'
        '      "role": "starter" | "main" | "side" | "dessert" | "beverage" | "other",\n'
        '      "recipe_name": "",\n'
        '      "servings": 0,\n'
        '      "notes": "",\n'
        '      "compatible_guests": ["Guest Name", ...],\n'
        '      "ingredients": [\n'
        '        {"ingredient_name": "", "quantity": 0, "unit": "", "prep": ""}\n'
        '      ]\n'
        '    }\n'
        '  ],\n'
        '  "coverage_summary": "one short paragraph describing how each constrained guest has something they can eat"\n'
        "}"
    )
    return (
        "You are designing a menu for a one-off event (not a recurring week). "
        "Your job: propose a crowd-pleasing menu for the majority, THEN ensure "
        "every guest with constraints has at least one compatible dish at each "
        "major role they'd expect (typically a main + a side). Do NOT over-"
        "restrict the whole menu just to accommodate one guest — design inclusive "
        "variants or dedicated dishes instead.\n\n"
        f"Event: {event.name}\n"
        f"Occasion: {event.occasion}\n"
        f"{date_line}\n"
        f"Total attendees (including host + plus-ones): {event.attendee_count}\n"
        f"Desired dish roles: {role_spec}\n"
        f"{notes_line}"
        f"{extra}\n\n"
        "Guests with constraints:\n"
        f"{guest_block}\n\n"
        "Rules:\n"
        "- `servings` on every dish must reflect the full attendee count (scale "
        "recipes accordingly — party portions, not single-serving).\n"
        "- NEVER include an allergen in a dish flagged as compatible with the "
        "allergic guest. Hard rule.\n"
        "- For each constrained guest, guarantee at least one `main` that works "
        "for them. Prefer dishes that naturally work for everyone over dedicated "
        "substitute plates when possible.\n"
        "- `compatible_guests` should list the *names* of guests the dish is "
        "explicitly safe for. Leave the list empty when the dish works for all.\n"
        "- `ingredients` should include quantities appropriate for the full "
        "headcount. Prefer common pantry items.\n"
        "- Return ONLY a JSON object matching this schema:\n"
        f"{schema}\n"
    )


def _parse_response(raw: str) -> _AIResponse:
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for event menu.") from exc
    try:
        return _AIResponse.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError(f"AI response didn't match expected shape: {exc}") from exc


def _resolve_coverage(
    compatible_names: list[str],
    name_lookup: dict[str, str],
) -> list[str]:
    """Map AI-returned guest names back to guest_ids. Unknown names are
    dropped silently — the AI occasionally invents names or says
    "everyone".
    """
    resolved: list[str] = []
    for raw in compatible_names:
        key = raw.strip().lower()
        if key in name_lookup:
            resolved.append(name_lookup[key])
    return resolved


def generate_event_menu(
    *,
    session: Session,
    event: Event,
    user_prompt: str = "",
    roles: list[str] | None = None,
    settings: Settings,
    user_settings: dict[str, str],
) -> dict[str, Any]:
    """Generate + persist a menu for the given event. Wipes any prior
    event meals + grocery items (grocery regenerates off meals in
    Phase 3). Returns a dict with `menu` (list of EventMeal-shaped
    payloads) and `coverage_summary`.
    """
    attendees = [(row.guest, row.plus_ones) for row in event.attendees if row.guest is not None]
    target = _resolve_target(settings, user_settings)
    prompt = _build_prompt(
        event=event,
        attendees=attendees,
        roles=list(roles) if roles else list(DEFAULT_ROLES),
        user_prompt=user_prompt,
    )
    raw = run_direct_provider(
        target=target,
        settings=settings,
        user_settings=user_settings,
        prompt=prompt,
    )
    parsed = _parse_response(raw)

    _, name_lookup = _describe_guests(attendees)

    meal_dicts: list[dict[str, Any]] = []
    for index, ai_meal in enumerate(parsed.menu):
        coverage = _resolve_coverage(ai_meal.compatible_guests, name_lookup)
        meal_dicts.append(
            {
                "role": ai_meal.role,
                "recipe_name": ai_meal.recipe_name,
                "servings": ai_meal.servings or float(event.attendee_count or 1),
                "notes": ai_meal.notes,
                "sort_order": index,
                "ai_generated": True,
                "approved": False,
                "constraint_coverage": coverage,
                "ingredients": [
                    ing.model_dump() for ing in ai_meal.ingredients
                ],
            }
        )

    replace_event_meals(session, event, meal_dicts)
    session.flush()

    return {
        "menu": meal_dicts,
        "coverage_summary": parsed.coverage_summary,
    }
