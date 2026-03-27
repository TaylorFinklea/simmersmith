from __future__ import annotations

import re
from datetime import date
from dataclasses import dataclass

from app.schemas import RecipeIngredientPayload, RecipePayload, RecipeStepPayload


@dataclass(frozen=True)
class VariationRule:
    terms: tuple[str, ...]
    replacement: str
    rationale: str


@dataclass(frozen=True)
class VariationPreset:
    key: str
    label: str
    title_prefix: str
    extra_tags: tuple[str, ...]
    guidance_note: str
    ingredient_rules: tuple[VariationRule, ...]


@dataclass(frozen=True)
class SuggestionPreset:
    key: str
    label: str
    title_prefix: str
    meal_type: str
    rationale_note: str
    extra_tags: tuple[str, ...] = ()
    variation_goal: str | None = None


VARIATION_PRESETS: tuple[VariationPreset, ...] = (
    VariationPreset(
        key="low_carb",
        label="Low-Carb",
        title_prefix="Low-Carb",
        extra_tags=("low-carb",),
        guidance_note="Reduce starch-heavy ingredients and keep the same flavor profile where possible.",
        ingredient_rules=(
            VariationRule(("spaghetti", "linguine", "fettuccine", "pasta", "noodle"), "zucchini noodles", "Swap noodles for zucchini noodles."),
            VariationRule(("rice",), "cauliflower rice", "Replace rice with cauliflower rice."),
            VariationRule(("potato", "potatoes"), "roasted cauliflower", "Replace potatoes with roasted cauliflower."),
            VariationRule(("tortilla", "wrap", "bun", "bread"), "lettuce wraps", "Swap bread-heavy components for lettuce wraps."),
        ),
    ),
    VariationPreset(
        key="dairy_free",
        label="Dairy-Free",
        title_prefix="Dairy-Free",
        extra_tags=("dairy-free",),
        guidance_note="Replace dairy with neutral, easy-to-find alternatives and keep the texture balanced.",
        ingredient_rules=(
            VariationRule(("milk", "whole milk", "skim milk", "buttermilk"), "unsweetened oat milk", "Use oat milk in place of dairy milk."),
            VariationRule(("butter",), "olive oil", "Use olive oil instead of butter."),
            VariationRule(("cream", "half-and-half"), "full-fat coconut milk", "Replace cream with coconut milk."),
            VariationRule(("cheese", "parmesan", "mozzarella", "cheddar"), "dairy-free cheese", "Use a dairy-free cheese alternative."),
            VariationRule(("yogurt", "sour cream"), "dairy-free yogurt", "Swap cultured dairy for dairy-free yogurt."),
        ),
    ),
    VariationPreset(
        key="gluten_free",
        label="Gluten-Free",
        title_prefix="Gluten-Free",
        extra_tags=("gluten-free",),
        guidance_note="Replace wheat-based ingredients with common gluten-free alternatives.",
        ingredient_rules=(
            VariationRule(("flour", "all-purpose flour", "wheat flour"), "gluten-free flour blend", "Swap wheat flour for a gluten-free flour blend."),
            VariationRule(("soy sauce",), "tamari", "Use tamari instead of soy sauce."),
            VariationRule(("breadcrumbs", "bread crumbs"), "gluten-free breadcrumbs", "Replace breadcrumbs with a gluten-free version."),
            VariationRule(("pasta", "spaghetti", "linguine", "fettuccine"), "gluten-free pasta", "Use gluten-free pasta."),
            VariationRule(("tortilla", "wrap"), "corn tortilla", "Use a gluten-free tortilla option."),
        ),
    ),
    VariationPreset(
        key="vegetarian",
        label="Vegetarian",
        title_prefix="Vegetarian",
        extra_tags=("vegetarian",),
        guidance_note="Replace meat with satisfying vegetarian protein and umami-friendly ingredients.",
        ingredient_rules=(
            VariationRule(("chicken", "chicken breast", "chicken thighs"), "extra-firm tofu", "Replace chicken with extra-firm tofu."),
            VariationRule(("ground beef", "beef", "steak"), "lentils and mushrooms", "Replace beef with lentils and mushrooms."),
            VariationRule(("ground turkey", "turkey"), "seasoned chickpeas", "Replace turkey with seasoned chickpeas."),
            VariationRule(("pork", "sausage", "bacon"), "smoked mushrooms", "Use smoked mushrooms for savory depth."),
        ),
    ),
    VariationPreset(
        key="kid_friendly",
        label="Kid-Friendly",
        title_prefix="Kid-Friendly",
        extra_tags=("kid-friendly",),
        guidance_note="Tone down heat, simplify flavors, and keep textures approachable.",
        ingredient_rules=(
            VariationRule(("jalapeno", "jalapeño", "serrano", "chili", "red pepper flakes", "hot sauce"), "mild bell pepper", "Swap heat-heavy ingredients for a milder pepper."),
            VariationRule(("onion"), "finely diced onion", "Use smaller onion pieces for a softer texture."),
        ),
    ),
    VariationPreset(
        key="pantry_friendly",
        label="Pantry-Friendly",
        title_prefix="Pantry-Friendly",
        extra_tags=("pantry-friendly",),
        guidance_note="Favor shelf-stable or freezer-friendly swaps that are easier to keep on hand.",
        ingredient_rules=(
            VariationRule(("fresh basil", "fresh parsley", "fresh cilantro"), "dried herbs", "Use dried herbs instead of fresh."),
            VariationRule(("fresh lemon", "fresh lime"), "bottled lemon juice", "Use bottled citrus if needed."),
            VariationRule(("fresh garlic",), "garlic powder", "Swap fresh garlic for garlic powder."),
            VariationRule(("spinach", "broccoli", "peas"), "frozen vegetables", "Replace fresh vegetables with frozen alternatives."),
        ),
    ),
)

SUGGESTION_PRESETS: tuple[SuggestionPreset, ...] = (
    SuggestionPreset(
        key="weeknight_dinner",
        label="Weeknight Dinner",
        title_prefix="Weeknight",
        meal_type="dinner",
        rationale_note="Favor a reliable dinner idea pulled from your saved rotation.",
        extra_tags=("weeknight", "ai-suggested"),
    ),
    SuggestionPreset(
        key="breakfast_rotation",
        label="Breakfast Rotation",
        title_prefix="Breakfast",
        meal_type="breakfast",
        rationale_note="Keep breakfast ideas moving without losing the recipes you already trust.",
        extra_tags=("breakfast-rotation", "ai-suggested"),
    ),
    SuggestionPreset(
        key="lunchbox_friendly",
        label="Lunchbox Friendly",
        title_prefix="Lunchbox",
        meal_type="lunch",
        rationale_note="Start from a saved recipe that can translate into a portable lunch.",
        extra_tags=("portable-lunch", "ai-suggested"),
    ),
    SuggestionPreset(
        key="pantry_reset",
        label="Pantry Reset",
        title_prefix="Pantry-Friendly",
        meal_type="dinner",
        rationale_note="Use your existing recipe history, but bias toward easier pantry-friendly swaps.",
        extra_tags=("pantry-friendly", "ai-suggested"),
        variation_goal="Pantry-Friendly",
    ),
    SuggestionPreset(
        key="kid_friendly_dinner",
        label="Kid-Friendly Dinner",
        title_prefix="Kid-Friendly",
        meal_type="dinner",
        rationale_note="Start from a dinner your library already suggests is family-usable, then soften the edges.",
        extra_tags=("kid-friendly", "ai-suggested"),
        variation_goal="Kid-Friendly",
    ),
)


def _normalized_goal(goal: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", goal.lower()).strip()


def resolve_variation_preset(goal: str) -> VariationPreset:
    normalized = _normalized_goal(goal)
    keyword_map = {
        "low carb": "low_carb",
        "dairy free": "dairy_free",
        "gluten free": "gluten_free",
        "vegetarian": "vegetarian",
        "kid friendly": "kid_friendly",
        "kids": "kid_friendly",
        "pantry": "pantry_friendly",
    }
    for phrase, preset_key in keyword_map.items():
        if phrase in normalized:
            return next(preset for preset in VARIATION_PRESETS if preset.key == preset_key)
    return next(preset for preset in VARIATION_PRESETS if preset.key == "pantry_friendly")


def resolve_suggestion_preset(goal: str) -> SuggestionPreset:
    normalized = _normalized_goal(goal)
    keyword_map = {
        "weeknight": "weeknight_dinner",
        "dinner": "weeknight_dinner",
        "breakfast": "breakfast_rotation",
        "lunch": "lunchbox_friendly",
        "lunchbox": "lunchbox_friendly",
        "portable": "lunchbox_friendly",
        "pantry": "pantry_reset",
        "kid": "kid_friendly_dinner",
        "family": "kid_friendly_dinner",
    }
    for phrase, preset_key in keyword_map.items():
        if phrase in normalized:
            return next(preset for preset in SUGGESTION_PRESETS if preset.key == preset_key)
    return next(preset for preset in SUGGESTION_PRESETS if preset.key == "weeknight_dinner")


def _replace_term(text: str, rule: VariationRule) -> str:
    updated = text
    for term in sorted(rule.terms, key=len, reverse=True):
        updated = re.sub(re.escape(term), rule.replacement, updated, flags=re.IGNORECASE)
    return updated


def _transform_ingredient(
    ingredient: RecipeIngredientPayload,
    preset: VariationPreset,
) -> tuple[RecipeIngredientPayload, list[str]]:
    updated_name = ingredient.ingredient_name
    changes: list[str] = []
    for rule in preset.ingredient_rules:
        if any(term in ingredient.ingredient_name.lower() for term in rule.terms):
            replaced_name = _replace_term(updated_name, rule)
            if replaced_name != updated_name:
                updated_name = replaced_name
                changes.append(rule.rationale)

    return (
        RecipeIngredientPayload(
            ingredient_id=None,
            ingredient_name=updated_name,
            normalized_name=ingredient.normalized_name,
            quantity=ingredient.quantity,
            unit=ingredient.unit,
            prep=ingredient.prep,
            category=ingredient.category,
            notes=ingredient.notes,
        ),
        changes,
    )


def _transform_step(step: RecipeStepPayload, preset: VariationPreset) -> RecipeStepPayload:
    updated_instruction = step.instruction
    for rule in preset.ingredient_rules:
        updated_instruction = _replace_term(updated_instruction, rule)

    return RecipeStepPayload(
        step_id=None,
        sort_order=step.sort_order,
        instruction=updated_instruction,
        substeps=[_transform_step(substep, preset) for substep in step.substeps],
    )


def build_variation_draft(
    base_recipe: RecipePayload,
    *,
    goal: str,
) -> tuple[RecipePayload, str, str]:
    preset = resolve_variation_preset(goal)
    ingredient_changes: list[str] = []
    transformed_ingredients: list[RecipeIngredientPayload] = []
    for ingredient in base_recipe.ingredients:
        transformed, changes = _transform_ingredient(ingredient, preset)
        transformed_ingredients.append(transformed)
        ingredient_changes.extend(changes)

    transformed_steps = [_transform_step(step, preset) for step in base_recipe.steps]
    deduped_tags = list(dict.fromkeys([*base_recipe.tags, *preset.extra_tags]))
    distinct_changes = list(dict.fromkeys(ingredient_changes))
    variation_summary = preset.guidance_note
    if distinct_changes:
        variation_summary = f"{preset.guidance_note} Key swaps: {' '.join(distinct_changes[:3])}"

    existing_notes = base_recipe.notes.strip()
    combined_notes = variation_summary if not existing_notes else f"{existing_notes}\n\nAI variation note: {variation_summary}"

    draft = RecipePayload(
        recipe_id=None,
        recipe_template_id=base_recipe.recipe_template_id,
        base_recipe_id=base_recipe.base_recipe_id or base_recipe.recipe_id,
        name=f"{preset.title_prefix} {base_recipe.name}",
        meal_type=base_recipe.meal_type,
        cuisine=base_recipe.cuisine,
        servings=base_recipe.servings,
        prep_minutes=base_recipe.prep_minutes,
        cook_minutes=base_recipe.cook_minutes,
        tags=deduped_tags,
        instructions_summary=base_recipe.instructions_summary,
        favorite=False,
        source="ai_variation",
        source_label=base_recipe.source_label,
        source_url=base_recipe.source_url,
        notes=combined_notes,
        memories=base_recipe.memories,
        last_used=None,
        ingredients=transformed_ingredients,
        steps=transformed_steps,
        nutrition_summary=None,
    )
    rationale = variation_summary
    return draft, rationale, preset.label


def _days_since(value: date | None) -> int | None:
    if value is None:
        return None
    return (date.today() - value).days


def _meal_type_matches(recipe: RecipePayload, meal_type: str) -> bool:
    return recipe.meal_type.strip().lower() == meal_type.strip().lower()


def _recipe_score(recipe: RecipePayload, preset: SuggestionPreset) -> tuple[int, int, int, str]:
    days_since_last_used = _days_since(recipe.last_used)
    recency_score = 0 if days_since_last_used is None else max(0, 30 - min(days_since_last_used, 30))
    return (
        1 if _meal_type_matches(recipe, preset.meal_type) else 0,
        1 if recipe.favorite else 0,
        recency_score + min(len(recipe.tags), 3) + (1 if recipe.source_label else 0),
        recipe.name.lower(),
    )


def _prefixed_title(prefix: str, name: str) -> str:
    trimmed_prefix = prefix.strip()
    trimmed_name = name.strip()
    if trimmed_name.lower().startswith(trimmed_prefix.lower()):
        return trimmed_name
    return f"{trimmed_prefix} {trimmed_name}".strip()


def build_suggestion_draft(
    saved_recipes: list[RecipePayload],
    *,
    goal: str,
) -> tuple[RecipePayload, str, str]:
    if not saved_recipes:
        raise ValueError("Save a few recipes before requesting an AI suggestion draft.")

    preset = resolve_suggestion_preset(goal)
    matching_recipes = [recipe for recipe in saved_recipes if _meal_type_matches(recipe, preset.meal_type)]
    fallback_used = not matching_recipes
    candidates = matching_recipes or saved_recipes
    anchor = sorted(candidates, key=lambda recipe: _recipe_score(recipe, preset), reverse=True)[0]

    variation_rationale = ""
    if preset.variation_goal:
        draft, variation_rationale, _ = build_variation_draft(anchor, goal=preset.variation_goal)
    else:
        draft = anchor.model_copy(deep=True)

    suggestion_note = preset.rationale_note
    if fallback_used:
        suggestion_note += f" No strong {preset.meal_type} match exists yet, so this starts from your closest saved recipe."
    if anchor.source_label:
        suggestion_note += f" Source signal: {anchor.source_label}."
    if variation_rationale:
        suggestion_note += f" {variation_rationale}"

    existing_notes = draft.notes.strip()
    combined_notes = (
        f"{existing_notes}\n\nAI suggestion note: {suggestion_note}".strip()
        if existing_notes
        else f"AI suggestion note: {suggestion_note}"
    )

    deduped_tags = list(dict.fromkeys([*draft.tags, *preset.extra_tags]))
    final_draft = draft.model_copy(
        update={
            "recipe_id": None,
            "base_recipe_id": anchor.base_recipe_id or anchor.recipe_id,
            "name": _prefixed_title(preset.title_prefix, anchor.name),
            "meal_type": preset.meal_type or draft.meal_type,
            "favorite": False,
            "source": "ai_suggestion",
            "source_label": anchor.source_label,
            "source_url": anchor.source_url,
            "notes": combined_notes,
            "last_used": None,
            "tags": deduped_tags,
        }
    )

    rationale = preset.rationale_note
    rationale += f" Started from {anchor.name}"
    if anchor.cuisine:
        rationale += f" with a {anchor.cuisine} lean"
    rationale += "."
    if fallback_used:
        rationale += f" No strong {preset.meal_type} match existed yet, so this used the closest saved recipe."
    return final_draft, rationale, preset.label
