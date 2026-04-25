"""AI-powered recipe pairings.

Given a recipe, suggest 3 dishes (sides, appetizers, desserts, drinks)
that pair well with it. Single AI call, strict-JSON output. Mirrors
the pattern in `substitution_ai.py`.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, Field, ValidationError

from app.config import Settings
from app.models import Recipe
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

logger = logging.getLogger(__name__)

ROLES: tuple[Literal["side", "appetizer", "dessert", "drink"], ...] = (
    "side",
    "appetizer",
    "dessert",
    "drink",
)
NUM_SUGGESTIONS = 3


class PairingOption(BaseModel):
    name: str
    role: str
    reason: str


class _AIResponse(BaseModel):
    suggestions: list[PairingOption] = Field(default_factory=list)


@dataclass(frozen=True)
class _Target:
    provider_name: str
    model: str


def _resolve_target(settings: Settings, user_settings: dict[str, str]) -> _Target:
    preferred = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    candidates: list[str] = []
    if preferred in SUPPORTED_DIRECT_PROVIDERS:
        candidates.append(preferred)
    for name in SUPPORTED_DIRECT_PROVIDERS:
        if name not in candidates:
            candidates.append(name)
    for name in candidates:
        available, _ = direct_provider_availability(
            name, settings=settings, user_settings=user_settings
        )
        if available:
            model = resolve_direct_model(name, settings=settings, user_settings=user_settings)
            return _Target(provider_name=name, model=model)
    raise RuntimeError("No direct AI provider is configured for pairings.")


def _build_prompt(*, recipe: Recipe) -> str:
    schema_hint = (
        '{"suggestions": [{"name": "", "role": "side|appetizer|dessert|drink", "reason": ""}]}'
    )
    cuisine = (recipe.cuisine or "unspecified").strip()
    meal_type = (recipe.meal_type or "unspecified").strip()
    return (
        "You are a thoughtful home-cook assistant. The user is making the "
        "recipe described below and wants three dishes that pair with it. "
        "Each pairing should complement (not duplicate) the main dish — vary "
        "the roles where it makes sense.\n\n"
        f"Recipe: {recipe.name}\n"
        f"Cuisine: {cuisine}\n"
        f"Meal type: {meal_type}\n\n"
        "Rules:\n"
        f"- Return exactly {NUM_SUGGESTIONS} suggestions.\n"
        "- `role` MUST be one of: side, appetizer, dessert, drink.\n"
        "- `name` is a short dish name (e.g., 'Caesar salad', 'Sparkling lemonade').\n"
        "- `reason` is one short sentence about why it pairs (texture, flavor, balance).\n"
        "- Don't propose the same dish family as the main (no other pasta if "
        "the main is pasta; no rich dessert if the main is already heavy).\n\n"
        "Return ONLY a JSON object matching this schema:\n"
        f"{schema_hint}\n"
    )


def _parse_response(raw: str) -> list[PairingOption]:
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for pairings.") from exc
    try:
        parsed = _AIResponse.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI response did not match the expected shape.") from exc
    suggestions: list[PairingOption] = []
    for entry in parsed.suggestions:
        name = entry.name.strip()
        role = entry.role.strip().lower()
        if not name or role not in ROLES:
            continue
        suggestions.append(
            PairingOption(name=name, role=role, reason=entry.reason.strip())
        )
    return suggestions[:NUM_SUGGESTIONS]


def suggest_pairings(
    *,
    recipe: Recipe,
    settings: Settings,
    user_settings: dict[str, str],
) -> list[PairingOption]:
    """Return up to `NUM_SUGGESTIONS` pairings for the given recipe.

    Raises RuntimeError if no provider is configured or the model returns
    an unparseable response. The route handler is expected to translate
    these into HTTP 502 — callers shouldn't have to know about parsing.
    """
    target = _resolve_target(settings, user_settings)
    execution_target = AssistantExecutionTarget(
        provider_kind="direct",
        source="pairings",
        provider_name=target.provider_name,
        model=target.model,
    )
    raw = run_direct_provider(
        target=execution_target,
        settings=settings,
        user_settings=user_settings,
        prompt=_build_prompt(recipe=recipe),
    )
    return _parse_response(raw)
