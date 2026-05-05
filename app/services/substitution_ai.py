"""AI-powered ingredient substitution suggestions.

Given a recipe and a single target ingredient, ask the AI for 3-5
alternatives that keep the recipe functional and flavor-coherent. The
prompt also tells the AI about any ingredient preferences the user has
on record so it doesn't suggest an ingredient the user already flagged.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass

from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.models import IngredientPreference, Recipe, RecipeIngredient
from app.schemas import IngredientSubstituteResponse, SubstitutionSuggestion
from app.services.assistant_ai import (
    AssistantExecutionTarget,
    extract_json_object,
    run_direct_provider,
)
from app.services.ai import (
    SUPPORTED_DIRECT_PROVIDERS,
    direct_provider_availability,
    resolve_direct_model,
)

logger = logging.getLogger(__name__)

MAX_SUGGESTIONS = 5
MIN_SUGGESTIONS = 3


class _AISuggestion(BaseModel):
    """Strict shape the AI must return for each suggestion."""

    name: str
    reason: str = ""
    quantity: str = ""
    unit: str = ""


class _AIResponse(BaseModel):
    suggestions: list[_AISuggestion]


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
        available, _ = direct_provider_availability(name, settings=settings, user_settings=user_settings)
        if available:
            model = resolve_direct_model(name, settings=settings, user_settings=user_settings)
            return _Target(provider_name=name, model=model)
    raise RuntimeError("No direct AI provider is configured for substitutions.")


def _ingredient_line(ingredient: RecipeIngredient) -> str:
    parts: list[str] = []
    if ingredient.quantity:
        parts.append(str(ingredient.quantity))
    if ingredient.unit:
        parts.append(ingredient.unit)
    if ingredient.ingredient_name:
        parts.append(ingredient.ingredient_name)
    if ingredient.prep:
        parts.append(f"({ingredient.prep})")
    return " ".join(parts).strip()


def _preference_note(preferences: list[IngredientPreference]) -> str:
    if not preferences:
        return ""
    bullets: list[str] = []
    for pref in preferences:
        if not pref.active:
            continue
        name = getattr(pref, "base_ingredient_name", None) or pref.base_ingredient_id
        if pref.choice_mode in {"avoid", "dislike", "allergy"}:
            bullets.append(f"- AVOID: {name} ({pref.choice_mode})")
        elif pref.preferred_variation_id or pref.preferred_brand:
            brand = pref.preferred_brand or pref.preferred_variation_id
            bullets.append(f"- PREFERS: {name} → {brand}")
    return "\n".join(bullets)


def _build_prompt(
    *,
    recipe: Recipe,
    target: RecipeIngredient,
    preferences: list[IngredientPreference],
    hint: str,
    user_settings: dict[str, str],
) -> str:
    all_ingredients = "\n".join(
        f"- {_ingredient_line(ing)}" for ing in recipe.ingredients
    )
    target_line = _ingredient_line(target) or target.ingredient_name
    hint_line = f"\nUser hint: {hint.strip()}" if hint.strip() else ""
    prefs = _preference_note(preferences)
    prefs_block = f"\n\nUser ingredient preferences:\n{prefs}" if prefs else ""
    schema_hint = (
        '{"suggestions": [{"name": "", "reason": "", "quantity": "", "unit": ""}]}'
    )
    from app.services.ai import unit_system_directive

    units_directive = unit_system_directive(user_settings)
    return (
        f"{units_directive}\n\n"
        "You are a cooking assistant helping a home cook substitute a single "
        "ingredient in a recipe. Propose "
        f"{MIN_SUGGESTIONS}-{MAX_SUGGESTIONS} substitutes that keep the dish "
        "functional (texture, binding, moisture) and flavor-coherent.\n\n"
        f"Recipe: {recipe.name}\n"
        f"Cuisine: {recipe.cuisine or 'unspecified'}\n"
        f"Meal type: {recipe.meal_type or 'unspecified'}\n\n"
        "All ingredients:\n"
        f"{all_ingredients}\n\n"
        f"Ingredient to substitute: {target_line}"
        f"{hint_line}"
        f"{prefs_block}\n\n"
        "Rules:\n"
        "- Do not suggest anything the user has flagged as AVOID/dislike/allergy.\n"
        "- Keep quantities realistic — substitutes are not always 1:1. Use the "
        "`quantity` and `unit` fields when a ratio adjustment is needed.\n"
        "- `reason` should be one short sentence. Explain *why* the swap works.\n"
        "- Prefer common pantry items over exotic ones.\n"
        f"- Return {MIN_SUGGESTIONS}-{MAX_SUGGESTIONS} options ordered best-first.\n\n"
        "Return ONLY a JSON object matching this schema:\n"
        f"{schema_hint}\n"
    )


def _parse_ai_response(raw: str) -> list[SubstitutionSuggestion]:
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for substitutions.") from exc
    try:
        parsed = _AIResponse.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI response did not match the expected shape.") from exc
    suggestions: list[SubstitutionSuggestion] = []
    for entry in parsed.suggestions[:MAX_SUGGESTIONS]:
        if not entry.name.strip():
            continue
        suggestions.append(
            SubstitutionSuggestion(
                name=entry.name.strip(),
                reason=entry.reason.strip(),
                quantity=entry.quantity.strip(),
                unit=entry.unit.strip(),
            )
        )
    return suggestions


def suggest_substitutions(
    *,
    recipe: Recipe,
    target_ingredient: RecipeIngredient,
    user_preferences: list[IngredientPreference],
    settings: Settings,
    user_settings: dict[str, str],
    hint: str = "",
) -> IngredientSubstituteResponse:
    """Return AI-generated substitution suggestions for a single recipe
    ingredient. Raises RuntimeError if no AI provider is configured or
    the model returns an unparseable response.
    """
    target = _resolve_target(settings, user_settings)
    prompt = _build_prompt(
        recipe=recipe,
        target=target_ingredient,
        preferences=user_preferences,
        hint=hint,
        user_settings=user_settings,
    )
    execution_target = AssistantExecutionTarget(
        provider_kind="direct",
        source="substitution",
        provider_name=target.provider_name,
        model=target.model,
    )
    raw = run_direct_provider(
        target=execution_target,
        settings=settings,
        user_settings=user_settings,
        prompt=prompt,
    )
    suggestions = _parse_ai_response(raw)
    return IngredientSubstituteResponse(
        ingredient_id=target_ingredient.id,
        original_name=target_ingredient.ingredient_name,
        suggestions=suggestions,
    )
