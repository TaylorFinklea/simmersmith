"""M29 build 53 — review-before-commit recipe drafting.

The two helpers here power the new recipe-draft funnel:

- `generate_recipe_draft_for_dish` builds a single AI recipe draft
  for an arbitrary dish (free-text name + servings + optional
  household constraints). Reused by both the event per-dish route
  and the new side-recipe route.
- `refine_recipe_draft` takes an existing draft + a user tweak
  prompt + an optional context hint and returns a refined draft.
  The iOS review sheet calls this in a loop until the user is
  happy.

Neither writes to the database — the iOS layer decides when (and
whether) the user is ready to commit.
"""
from __future__ import annotations

import json
from typing import Any

from app.config import Settings
from app.services.ai import unit_system_directive
from app.services.assistant_ai import (
    extract_json_object,
    run_direct_provider,
)
from app.services.event_ai import _resolve_target


_SCHEMA_HINT = (
    '{\n'
    '  "name": "",\n'
    '  "meal_type": "",\n'
    '  "cuisine": "",\n'
    '  "servings": 0,\n'
    '  "prep_minutes": 0,\n'
    '  "cook_minutes": 0,\n'
    '  "tags": [],\n'
    '  "instructions_summary": "",\n'
    '  "ingredients": [\n'
    '    {"ingredient_name": "", "quantity": 0, "unit": "", "prep": "", "notes": ""}\n'
    '  ],\n'
    '  "steps": [\n'
    '    {"order_index": 1, "instruction": ""}\n'
    '  ]\n'
    "}"
)


def _build_dish_prompt(
    *,
    dish_name: str,
    servings: int,
    user_prompt: str,
    constraints_block: str,
    context_label: str,
    user_settings: dict[str, str],
) -> str:
    """Generic single-recipe prompt. `context_label` is something
    like "the event Easter Brunch" or "a side for the meal Lasagna" —
    a short noun phrase the AI uses to keep the recipe scoped.
    `constraints_block` lists guest allergies / household notes
    relevant to the dish (empty string when no constraints)."""
    units_directive = unit_system_directive(user_settings)
    extra = f"\nUser hint: {user_prompt.strip()}" if user_prompt.strip() else ""
    constraint_section = (
        f"Constraints to honor:\n{constraints_block}\n"
        if constraints_block.strip()
        else ""
    )
    return (
        f"{units_directive}\n\n"
        f"You are writing ONE detailed recipe for the dish \"{dish_name}\" "
        f"on {context_label}.\n"
        f"This recipe must serve {servings} people total — scale ingredient "
        "quantities accordingly. Keep instructions usable in a real kitchen.\n\n"
        f"{constraint_section}"
        f"{extra}\n\n"
        "Rules:\n"
        "- Provide complete ingredient quantities. Avoid bare names like just \"salt\".\n"
        "- `steps[].instruction` must be a numbered cooking step, not a heading.\n"
        "- NEVER include a known allergen from the constraints block above.\n"
        "- Return ONLY a JSON object matching this schema:\n"
        f"{_SCHEMA_HINT}\n"
    )


def _coerce_draft(payload: dict[str, Any], *, fallback_name: str, fallback_servings: int) -> dict[str, Any]:
    payload.setdefault("name", fallback_name)
    payload.setdefault("ingredients", [])
    payload.setdefault("steps", [])
    payload.setdefault("tags", [])
    if not payload.get("servings"):
        payload["servings"] = float(fallback_servings)
    return payload


def _provider_call_with_json_retry(
    *,
    target: Any,
    settings: Settings,
    user_settings: dict[str, str],
    prompt: str,
    label: str,
) -> dict[str, Any]:
    """M29 build 54: retry once on invalid JSON.

    The AI occasionally wraps its response in markdown fences or
    leading prose despite the schema directive. `extract_json_object`
    handles the common cases, but a stubborn first attempt sometimes
    fails. We retry once with a tightened reminder before raising —
    cheap insurance against transient parse failures the user
    reported on TestFlight 53.
    """
    retry_prompt = (
        prompt
        + "\n\nIMPORTANT: Your previous response could not be parsed as JSON. "
        "Return ONLY the JSON object — no markdown fences, no prose, no commentary."
    )
    last_error: Exception | None = None
    for attempt_prompt in (prompt, retry_prompt):
        raw = run_direct_provider(
            target=target,
            settings=settings,
            user_settings=user_settings,
            prompt=attempt_prompt,
        )
        candidate = extract_json_object(raw)
        try:
            return json.loads(candidate)
        except json.JSONDecodeError as exc:
            last_error = exc
            continue
    raise RuntimeError(f"AI returned invalid JSON for {label}.") from last_error


def generate_recipe_draft_for_dish(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    dish_name: str,
    servings: int,
    user_prompt: str = "",
    constraints_block: str = "",
    context_label: str,
) -> dict[str, Any]:
    """Single AI call → `RecipePayload`-shaped dict. No DB writes.

    `context_label` should be a short noun phrase (e.g. "the event
    Easter Brunch", "a side for Wednesday's Lasagna") that frames
    the recipe in the system prompt.
    """
    target = _resolve_target(settings, user_settings)
    prompt = _build_dish_prompt(
        dish_name=dish_name,
        servings=servings,
        user_prompt=user_prompt,
        constraints_block=constraints_block,
        context_label=context_label,
        user_settings=user_settings,
    )
    payload = _provider_call_with_json_retry(
        target=target,
        settings=settings,
        user_settings=user_settings,
        prompt=prompt,
        label="recipe draft",
    )
    return _coerce_draft(payload, fallback_name=dish_name, fallback_servings=servings)


def refine_recipe_draft(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    draft: dict[str, Any],
    prompt: str,
    context_hint: str = "",
) -> dict[str, Any]:
    """Apply a user tweak to an existing draft. The model gets the
    current draft as JSON + the user's tweak prompt + an optional
    context hint, and returns the full refined draft.

    No DB writes — the caller decides when to persist. Idempotent in
    the sense that an empty/whitespace prompt returns the input
    unchanged (saves a roundtrip when the iOS button is tapped with
    no text).
    """
    cleaned = (prompt or "").strip()
    if not cleaned:
        return draft
    target = _resolve_target(settings, user_settings)
    units_directive = unit_system_directive(user_settings)
    fallback_name = str(draft.get("name") or "Untitled")
    fallback_servings = int(draft.get("servings") or 4) if draft.get("servings") else 4
    context_block = (
        f"Context: {context_hint.strip()}\n\n" if context_hint.strip() else ""
    )
    full_prompt = (
        f"{units_directive}\n\n"
        f"{context_block}"
        "You are refining an existing recipe draft. Apply the user's "
        "tweak below, return the COMPLETE refined recipe (not just a "
        "patch). Preserve fields that don't conflict with the tweak.\n\n"
        "Current draft (JSON):\n"
        f"{json.dumps(draft, ensure_ascii=False, indent=2)}\n\n"
        f"User tweak: {cleaned}\n\n"
        "Rules:\n"
        "- Recompute ingredient quantities + steps when the tweak "
        "implies it (e.g. \"smaller portion\", \"swap chicken for tofu\").\n"
        "- Keep instructions usable in a real kitchen.\n"
        "- Return ONLY a JSON object matching this schema:\n"
        f"{_SCHEMA_HINT}\n"
    )
    payload = _provider_call_with_json_retry(
        target=target,
        settings=settings,
        user_settings=user_settings,
        prompt=full_prompt,
        label="refined draft",
    )
    return _coerce_draft(payload, fallback_name=fallback_name, fallback_servings=fallback_servings)
