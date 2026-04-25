"""AI inference of a recipe's difficulty score (1-5) + kid-friendly flag.

Called opportunistically on recipe save when both fields are unset. The
caller wraps this in `try / except` so an AI failure never blocks a save.
Mirrors `substitution_ai.py` / `pairing_ai.py` strict-JSON pattern.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass

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


class DifficultyAssessment(BaseModel):
    """Strict shape the AI must return."""

    score: int = Field(ge=1, le=5)
    kid_friendly: bool = False
    reason: str = ""


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
    raise RuntimeError("No direct AI provider is configured for difficulty inference.")


def _ingredient_lines(recipe: Recipe) -> list[str]:
    lines: list[str] = []
    for ing in recipe.ingredients:
        parts: list[str] = []
        if ing.quantity:
            parts.append(str(ing.quantity))
        if ing.unit:
            parts.append(ing.unit)
        if ing.ingredient_name:
            parts.append(ing.ingredient_name)
        if ing.prep:
            parts.append(f"({ing.prep})")
        line = " ".join(parts).strip()
        if line:
            lines.append(line)
    return lines


def _step_lines(recipe: Recipe) -> list[str]:
    return [step.instruction.strip() for step in recipe.steps if step.instruction.strip()]


def _build_prompt(*, recipe: Recipe) -> str:
    schema_hint = (
        '{"score": 1-5, "kid_friendly": true|false, "reason": "..."}'
    )
    ingredients = "\n".join(f"- {line}" for line in _ingredient_lines(recipe)) or "(none)"
    steps = "\n".join(f"{idx + 1}. {line}" for idx, line in enumerate(_step_lines(recipe))) or "(none)"
    return (
        "Score this recipe's difficulty for a home cook on a 1-5 scale and "
        "decide whether it's safe and engaging for a kid (~6-12) to help cook "
        "with adult supervision. Return JSON only.\n\n"
        f"Recipe: {recipe.name}\n"
        f"Cuisine: {recipe.cuisine or 'unspecified'}\n"
        f"Meal type: {recipe.meal_type or 'unspecified'}\n"
        f"Prep minutes: {recipe.prep_minutes or '—'}\n"
        f"Cook minutes: {recipe.cook_minutes or '—'}\n\n"
        "Ingredients:\n"
        f"{ingredients}\n\n"
        "Steps:\n"
        f"{steps}\n\n"
        "Rules:\n"
        "- 1 = trivial (toast, smoothie). 2 = beginner. 3 = needs a little "
        "experience. 4 = several techniques in flight. 5 = pro-level "
        "(croissants, mole, fermented anything).\n"
        "- `kid_friendly: true` only when a child can meaningfully help "
        "(measuring, mixing, decorating). Sharp knives, hot oil, raw meat "
        "handling, alcohol → false.\n"
        "- `reason` is one short sentence justifying the score.\n\n"
        f"Return ONLY a JSON object matching:\n{schema_hint}\n"
    )


def _parse_response(raw: str) -> DifficultyAssessment:
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for difficulty.") from exc
    try:
        return DifficultyAssessment.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI difficulty response did not match the expected shape.") from exc


def infer_recipe_difficulty(
    *,
    recipe: Recipe,
    settings: Settings,
    user_settings: dict[str, str],
) -> DifficultyAssessment:
    """Return a `DifficultyAssessment` for the given recipe.

    Raises RuntimeError if no provider is configured or the model returns
    unparseable output. Callers (e.g., the `POST /api/recipes` route) wrap
    this in try/except so a save never fails because AI is offline.
    """
    target = _resolve_target(settings, user_settings)
    execution_target = AssistantExecutionTarget(
        provider_kind="direct",
        source="recipe_difficulty",
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
