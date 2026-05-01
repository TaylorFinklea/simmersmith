from __future__ import annotations

import hashlib
import math
import re
from collections import defaultdict
from fractions import Fraction
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import GroceryItem, Recipe, RecipeIngredient, Staple, Week, WeekMeal, WeekMealIngredient
from app.services.ingredient_catalog import choice_for_base_ingredient
from app.services.weeks import invalidate_week


UNIT_MAP = {
    "count": "ct",
    "counts": "ct",
    "ct": "ct",
    "each": "ea",
    "ea": "ea",
    "egg": "ea",
    "eggs": "ea",
    "pound": "lb",
    "pounds": "lb",
    "lb": "lb",
    "lbs": "lb",
    "ounce": "oz",
    "ounces": "oz",
    "oz": "oz",
    "fluid ounce": "fl oz",
    "fluid ounces": "fl oz",
    "fl oz": "fl oz",
    "gallon": "gal",
    "gallons": "gal",
    "gal": "gal",
    "cup": "cup",
    "cups": "cup",
    "tablespoon": "tbsp",
    "tablespoons": "tbsp",
    "tbsp": "tbsp",
    "teaspoon": "tsp",
    "teaspoons": "tsp",
    "tsp": "tsp",
    "package": "pkg",
    "packages": "pkg",
    "pkg": "pkg",
    "can": "can",
    "cans": "can",
    "bag": "bag",
    "bags": "bag",
    "bunch": "bunch",
    "bunches": "bunch",
    "clove": "clove",
    "cloves": "clove",
    "slice": "slice",
    "slices": "slice",
}


def normalize_name(value: str) -> str:
    cleaned = value.lower().strip()
    cleaned = cleaned.replace("&", " and ")
    cleaned = re.sub(r"[^a-z0-9\s]", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


def normalize_unit(value: object) -> str:
    text = normalize_name(str(value or ""))
    return UNIT_MAP.get(text, text)


def parse_quantity(value: object) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        pass
    mixed_match = re.fullmatch(r"(\d+)\s+(\d+/\d+)", text)
    if mixed_match:
        return float(int(mixed_match.group(1)) + Fraction(mixed_match.group(2)))
    fraction_match = re.fullmatch(r"\d+/\d+", text)
    if fraction_match:
        return float(Fraction(text))
    return None


def ingredient_id(normalized_name_value: str, unit: str, source: str) -> str:
    digest = hashlib.sha1(f"{normalized_name_value}|{unit}|{source}".encode("utf-8")).hexdigest()[:8]
    stem = re.sub(r"[^a-z0-9]+", "-", normalized_name_value).strip("-") or "item"
    suffix = f"-{unit}" if unit else ""
    return f"{stem}{suffix}-{digest}"


def source_label(meal: WeekMeal) -> str:
    parts = [meal.day_name, meal.slot, meal.recipe_name]
    return " / ".join(part for part in parts if part)


def quantity_display(quantity: float | None) -> str:
    if quantity is None:
        return ""
    if math.isclose(quantity, round(quantity), rel_tol=0, abs_tol=1e-9):
        return str(int(round(quantity)))
    return f"{quantity:.2f}".rstrip("0").rstrip(".")


def staple_names(session: Session, household_id: str) -> set[str]:
    staples = session.scalars(
        select(Staple).where(Staple.household_id == household_id, Staple.is_active.is_(True))
    ).all()
    return {staple.normalized_name for staple in staples}


def build_grocery_rows_for_week(session: Session, user_id: str, household_id: str, week: Week) -> list[dict[str, Any]]:
    meals = list(
        session.scalars(
            select(WeekMeal).where(WeekMeal.week_id == week.id).order_by(WeekMeal.meal_date, WeekMeal.sort_order)
        ).all()
    )
    meal_ids = [m.id for m in meals]
    recipe_ids = [m.recipe_id for m in meals if m.recipe_id]

    recipes = {
        recipe.id: recipe
        for recipe in session.scalars(select(Recipe).where(Recipe.id.in_(recipe_ids))).all()
    } if recipe_ids else {}

    ingredients_by_recipe: dict[str, list[RecipeIngredient]] = defaultdict(list)
    if recipe_ids:
        for ingredient in session.scalars(
            select(RecipeIngredient).where(RecipeIngredient.recipe_id.in_(recipe_ids))
        ).all():
            ingredients_by_recipe[ingredient.recipe_id].append(ingredient)

    inline_ingredients_by_meal: dict[str, list[WeekMealIngredient]] = defaultdict(list)
    if meal_ids:
        for ingredient in session.scalars(
            select(WeekMealIngredient).where(WeekMealIngredient.week_meal_id.in_(meal_ids))
        ).all():
            inline_ingredients_by_meal[ingredient.week_meal_id].append(ingredient)

    staples = staple_names(session, household_id)
    aggregations: dict[tuple[str, str, str], dict[str, Any]] = {}

    for meal in meals:
        recipe = recipes.get(meal.recipe_id or "")
        if recipe:
            base_servings = recipe.servings or 1.0
            meal_servings = meal.servings or base_servings
            factor = meal.scale_multiplier or (meal_servings / base_servings if base_servings else 1.0)
            ingredients = ingredients_by_recipe.get(recipe.id, [])
        else:
            factor = 1.0
            ingredients = inline_ingredients_by_meal.get(meal.id, [])

        for ingredient in ingredients:
            ingredient_name = ingredient.ingredient_name.strip()
            if not ingredient_name:
                continue

            normalized = normalize_name(ingredient.normalized_name or ingredient_name)
            if normalized in staples:
                continue

            unit = normalize_unit(ingredient.unit)
            quantity = ingredient.quantity * factor if ingredient.quantity is not None else None
            quantity_text = "" if quantity is not None else str(getattr(ingredient, "quantity_text", "") or "")
            locked_variation_id = (
                ingredient.ingredient_variation_id
                if getattr(ingredient, "resolution_status", "") == "locked"
                else ""
            )
            base_key = getattr(ingredient, "base_ingredient_id", "") or normalized
            key = (base_key, locked_variation_id, unit, quantity_text)
            bucket = aggregations.get(key)
            if bucket is None:
                bucket = {
                    "ingredient_name": ingredient_name,
                    "normalized_name": normalized,
                    "base_ingredient_id": getattr(ingredient, "base_ingredient_id", None),
                    "ingredient_variation_id": getattr(ingredient, "ingredient_variation_id", None),
                    "resolution_status": getattr(ingredient, "resolution_status", "unresolved"),
                    "total_quantity": 0.0 if quantity is not None else None,
                    "unit": unit,
                    "quantity_text": "",
                    "category": ingredient.category,
                    "source_meals": set(),
                    "notes": set(),
                    "review_flag": "",
                }
                aggregations[key] = bucket

            if quantity is not None:
                bucket["total_quantity"] = float(bucket["total_quantity"] or 0) + quantity
            elif quantity_text:
                bucket["quantity_text"] = quantity_text
                bucket["review_flag"] = "quantity review"

            if ingredient.notes:
                bucket["notes"].add(ingredient.notes)
            if ingredient.prep:
                bucket["notes"].add(ingredient.prep)
            if ingredient.category and not bucket["category"]:
                bucket["category"] = ingredient.category
            bucket["source_meals"].add(source_label(meal))

    rows = []
    for bucket in aggregations.values():
        base, chosen_variation, chosen_status = choice_for_base_ingredient(
            session,
            user_id=user_id,
            base_ingredient_id=bucket.get("base_ingredient_id"),
            recipe_variation_id=bucket.get("ingredient_variation_id"),
            recipe_resolution_status=str(bucket.get("resolution_status") or "unresolved"),
        )
        ingredient_name = (
            chosen_variation.name
            if chosen_variation is not None
            else base.name
            if base is not None
            else bucket["ingredient_name"]
        )
        normalized_name = (
            chosen_variation.normalized_name
            if chosen_variation is not None
            else base.normalized_name
            if base is not None
            else bucket["normalized_name"]
        )
        total_quantity = bucket["total_quantity"]
        if isinstance(total_quantity, float):
            total_quantity = round(total_quantity, 2)
        review_flag = bucket["review_flag"]
        if base is None:
            review_flag = review_flag or "ingredient review"
        rows.append(
            {
                "ingredient_name": ingredient_name,
                "normalized_name": normalized_name,
                "base_ingredient_id": base.id if base is not None else None,
                "base_ingredient_name": base.name if base is not None else None,
                "ingredient_variation_id": chosen_variation.id if chosen_variation is not None else None,
                "ingredient_variation_name": chosen_variation.name if chosen_variation is not None else None,
                "resolution_status": chosen_status,
                "total_quantity": total_quantity,
                "unit": bucket["unit"],
                "quantity_text": bucket["quantity_text"],
                "category": bucket["category"],
                "source_meals": "; ".join(sorted(bucket["source_meals"])),
                "notes": "; ".join(sorted(bucket["notes"])),
                "review_flag": review_flag,
            }
        )
    rows.sort(key=lambda row: ((row.get("category") or "").lower(), row["ingredient_name"].lower()))
    return rows


def regenerate_grocery_for_week(session: Session, user_id: str, household_id: str, week: Week) -> list[GroceryItem]:
    invalidate_week(session, week)
    session.execute(delete(GroceryItem).where(GroceryItem.week_id == week.id))
    session.flush()

    rows = build_grocery_rows_for_week(session, user_id, household_id, week)
    created: list[GroceryItem] = []
    for row in rows:
        grocery_item = GroceryItem(
            week_id=week.id,
            base_ingredient_id=row["base_ingredient_id"],
            ingredient_variation_id=row["ingredient_variation_id"],
            ingredient_name=row["ingredient_name"],
            normalized_name=row["normalized_name"],
            total_quantity=row["total_quantity"],
            unit=row["unit"],
            quantity_text=row["quantity_text"],
            category=row["category"],
            source_meals=row["source_meals"],
            notes=row["notes"],
            review_flag=row["review_flag"],
            resolution_status=row["resolution_status"],
        )
        session.add(grocery_item)
        created.append(grocery_item)

    session.flush()
    return created
