from __future__ import annotations

import json
import re
from datetime import date
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import Recipe, RecipeIngredient, RecipeStep, Week, utcnow
from app.services.grocery import normalize_name

RECIPE_OVERRIDE_FIELDS = {
    "recipe_template_id",
    "meal_type",
    "cuisine",
    "servings",
    "prep_minutes",
    "cook_minutes",
    "tags",
    "instructions_summary",
    "favorite",
    "source",
    "source_label",
    "source_url",
    "notes",
    "memories",
    "ingredients",
    "steps",
}


def get_recipe(session: Session, household_id: str, recipe_id: str) -> Recipe | None:
    statement = (
        select(Recipe)
        .where(Recipe.household_id == household_id, Recipe.id == recipe_id)
        .options(
            selectinload(Recipe.recipe_template),
            selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.steps),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.base_recipe).selectinload(Recipe.steps),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.variants).selectinload(Recipe.steps),
        )
    )
    return session.scalar(statement)


def list_recipes(session: Session, household_id: str, include_archived: bool = False) -> list[Recipe]:
    statement = (
        select(Recipe)
        .where(Recipe.household_id == household_id)
        .options(
            selectinload(Recipe.recipe_template),
            selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.steps),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.base_recipe).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.base_recipe).selectinload(Recipe.steps),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.base_ingredient),
            selectinload(Recipe.variants).selectinload(Recipe.ingredients).selectinload(RecipeIngredient.ingredient_variation),
            selectinload(Recipe.variants).selectinload(Recipe.steps),
        )
        .order_by(Recipe.name)
    )
    if not include_archived:
        statement = statement.where(Recipe.archived.is_(False))
    return list(session.scalars(statement).all())


def archive_recipe(recipe: Recipe) -> Recipe:
    recipe.archived = True
    recipe.archived_at = utcnow()
    recipe.updated_at = utcnow()
    return recipe


def restore_recipe(recipe: Recipe) -> Recipe:
    recipe.archived = False
    recipe.archived_at = None
    recipe.updated_at = utcnow()
    return recipe


def split_summary_into_steps(summary: str) -> list[str]:
    cleaned = summary.strip()
    if not cleaned:
        return []
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if len(lines) > 1:
        return [re.sub(r"^\d+[\).\s-]+", "", line).strip() for line in lines]
    parts = re.split(r"(?:\s*\d+[\).\s-]+)|(?:\.\s+)", cleaned)
    normalized = [part.strip() for part in parts if part and part.strip()]
    return normalized or [cleaned]


def normalize_tag_list(value: object) -> list[str]:
    if isinstance(value, list):
        raw_items = value
    else:
        text = str(value or "").strip()
        if not text:
            raw_items = []
        else:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = None
            if isinstance(parsed, list):
                raw_items = parsed
            else:
                raw_items = re.split(r"[,;\n]+", text)

    tags: list[str] = []
    seen: set[str] = set()
    for item in raw_items:
        cleaned = str(item).strip()
        if not cleaned:
            continue
        normalized = normalize_name(cleaned)
        if normalized in seen:
            continue
        seen.add(normalized)
        tags.append(cleaned)
    return tags


def serialize_tag_list(tags: list[str]) -> str:
    return json.dumps(normalize_tag_list(tags))


def summarize_steps(steps: list[dict[str, Any]]) -> str:
    if not steps:
        return ""
    lines: list[str] = []
    for index, step in enumerate(steps, start=1):
        lines.append(f"{index}. {step['instruction']}")
        for sub_index, substep in enumerate(step.get("substeps", []), start=1):
            letter = chr(ord("a") + sub_index - 1)
            lines.append(f"   {letter}. {substep['instruction']}")
    return "\n".join(lines)


def ingredient_payload(ingredient: RecipeIngredient) -> dict[str, object]:
    return {
        "ingredient_id": ingredient.id,
        "ingredient_name": ingredient.ingredient_name,
        "normalized_name": ingredient.normalized_name,
        "base_ingredient_id": ingredient.base_ingredient_id,
        "base_ingredient_name": ingredient.base_ingredient.name if ingredient.base_ingredient is not None else None,
        "ingredient_variation_id": ingredient.ingredient_variation_id,
        "ingredient_variation_name": (
            ingredient.ingredient_variation.name if ingredient.ingredient_variation is not None else None
        ),
        "resolution_status": ingredient.resolution_status,
        "quantity": ingredient.quantity,
        "unit": ingredient.unit,
        "prep": ingredient.prep,
        "category": ingredient.category,
        "notes": ingredient.notes,
    }


def step_payload(step: RecipeStep) -> dict[str, object]:
    return {"step_id": step.id, "sort_order": step.sort_order, "instruction": step.instruction, "substeps": []}


def nested_step_payloads(steps: list[RecipeStep]) -> list[dict[str, object]]:
    ordered = sorted(steps, key=lambda step: ((step.parent_step_id or ""), step.sort_order, step.id))
    child_lookup: dict[str, list[dict[str, object]]] = {}
    roots: list[dict[str, object]] = []
    for step in ordered:
        payload = step_payload(step)
        if step.parent_step_id:
            child_lookup.setdefault(step.parent_step_id, []).append(payload)
        else:
            roots.append(payload)
    for root in roots:
        root["substeps"] = child_lookup.get(str(root["step_id"]), [])
    return roots


def decode_overrides(recipe: Recipe) -> dict[str, Any]:
    if not recipe.override_payload_json:
        return {}
    try:
        payload = json.loads(recipe.override_payload_json)
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def effective_recipe_data(recipe: Recipe) -> dict[str, Any]:
    base_data = None
    if recipe.base_recipe is not None:
        base_data = effective_recipe_data(recipe.base_recipe)

    data = {
        "recipe_template_id": recipe.recipe_template_id,
        "base_recipe_id": recipe.base_recipe_id,
        "name": recipe.name,
        "meal_type": recipe.meal_type,
        "cuisine": recipe.cuisine,
        "servings": recipe.servings,
        "prep_minutes": recipe.prep_minutes,
        "cook_minutes": recipe.cook_minutes,
        "tags": normalize_tag_list(recipe.tags),
        "instructions_summary": recipe.instructions_summary,
        "favorite": recipe.favorite,
        "source": recipe.source,
        "source_label": recipe.source_label,
        "source_url": recipe.source_url,
        "notes": recipe.notes,
        "memories": recipe.memories,
        "last_used": recipe.last_used,
        "ingredients": [ingredient_payload(ingredient) for ingredient in recipe.ingredients],
        "steps": nested_step_payloads(recipe.steps),
    }
    if base_data is None:
        if not data["steps"] and data["instructions_summary"]:
            data["steps"] = [
                {"step_id": None, "sort_order": index, "instruction": instruction}
                for index, instruction in enumerate(split_summary_into_steps(data["instructions_summary"]), start=1)
            ]
        if not data["instructions_summary"] and data["steps"]:
            data["instructions_summary"] = summarize_steps(data["steps"])
        return data

    overrides = decode_overrides(recipe)
    resolved = {
        **base_data,
        "recipe_template_id": recipe.recipe_template_id or base_data.get("recipe_template_id"),
        "base_recipe_id": recipe.base_recipe_id,
        "name": recipe.name,
        "last_used": recipe.last_used,
    }
    for field_name in RECIPE_OVERRIDE_FIELDS:
        if field_name in overrides:
            resolved[field_name] = overrides[field_name]
    if not resolved.get("instructions_summary") and resolved.get("steps"):
        resolved["instructions_summary"] = summarize_steps(resolved["steps"])
    if not resolved.get("steps") and resolved.get("instructions_summary"):
        resolved["steps"] = [
            {"step_id": None, "sort_order": index, "instruction": instruction}
            for index, instruction in enumerate(split_summary_into_steps(resolved["instructions_summary"]), start=1)
        ]
    return resolved


def family_last_used(recipe: Recipe) -> date | None:
    root = recipe.base_recipe or recipe
    candidates = [root.last_used] + [variant.last_used for variant in root.variants]
    dates = [candidate for candidate in candidates if candidate is not None]
    return max(dates) if dates else None


def days_since(value: date | None) -> int | None:
    if value is None:
        return None
    return (date.today() - value).days


def source_key(payload: dict[str, Any]) -> str:
    return str(payload.get("source_label") or payload.get("source") or "manual").strip().lower()


def source_counts(recipes: list[Recipe]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for recipe in recipes:
        key = source_key(effective_recipe_data(recipe))
        counts[key] = counts.get(key, 0) + 1
    return counts


def effective_override_fields(recipe: Recipe) -> list[str]:
    if recipe.base_recipe is None:
        return []
    fields = sorted(decode_overrides(recipe).keys())
    if recipe.name != recipe.base_recipe.name and "name" not in fields:
        fields.insert(0, "name")
    return fields


def mark_week_recipe_usage(session: Session, week: Week) -> None:
    latest_usage: dict[str, date] = {}
    for meal in week.meals:
        if not meal.recipe_id:
            continue
        recipe = session.get(Recipe, meal.recipe_id)
        if recipe is None:
            continue
        latest_usage[recipe.id] = max(latest_usage.get(recipe.id, meal.meal_date), meal.meal_date)
        if recipe.base_recipe is not None:
            latest_usage[recipe.base_recipe.id] = max(
                latest_usage.get(recipe.base_recipe.id, meal.meal_date),
                meal.meal_date,
            )

    for recipe_id, used_on in latest_usage.items():
        recipe = session.get(Recipe, recipe_id)
        if recipe is None:
            continue
        if recipe.last_used is None or used_on > recipe.last_used:
            recipe.last_used = used_on
            recipe.updated_at = utcnow()
