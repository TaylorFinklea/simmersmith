from __future__ import annotations

import re
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
