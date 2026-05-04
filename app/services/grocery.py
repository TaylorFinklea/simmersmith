from __future__ import annotations

import hashlib
import math
import re
from collections import defaultdict
from datetime import datetime, timezone
from fractions import Fraction
from typing import Any

from sqlalchemy import select
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
    aggregations: dict[tuple[str, str, str, str], dict[str, Any]] = {}

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


def _key_for_row(row: dict[str, Any]) -> tuple[str, str, str, str]:
    """Match key used by smart merge. Mirrors the aggregation key in
    `build_grocery_rows_for_week` so a fresh row matches the existing
    `GroceryItem` it was derived from on a prior regen.
    """
    base = (row.get("base_ingredient_id") or row.get("normalized_name") or "")
    locked_variation = (
        row.get("ingredient_variation_id") if row.get("resolution_status") == "locked" else ""
    ) or ""
    return (str(base), str(locked_variation), row.get("unit") or "", row.get("quantity_text") or "")


def _key_for_item(item: GroceryItem) -> tuple[str, str, str, str]:
    base = item.base_ingredient_id or item.normalized_name or ""
    locked_variation = (
        item.ingredient_variation_id if item.resolution_status == "locked" else ""
    ) or ""
    return (str(base), str(locked_variation), item.unit or "", item.quantity_text or "")


def _has_event_attribution(item: GroceryItem) -> bool:
    """True when an item carries any event-merged contribution.
    Pre-M22.2 rows used a `+event:` notes tag and the
    `source_meals="event:<name>"` marker; post-M22.2 the truth lives
    in the structured `event_quantity` column.

    Smart-merge regen treats these specially: pure event-only rows
    (no week-meal contribution) are left alone; mixed rows have their
    week-meal portion (`total_quantity`) refreshed while
    `event_quantity` stays put — owned by the event merge / unmerge
    pair.
    """
    if item.event_quantity is not None and item.event_quantity > 0:
        return True
    if (item.source_meals or "").startswith("event:"):
        return True
    return "+event:" in (item.notes or "")


def _is_event_only(item: GroceryItem) -> bool:
    """True for rows that were created purely by event merge — no
    week-meal aggregation feeds them. Smart merge does not delete
    these even when they don't match a fresh row."""
    if (item.event_quantity is None or item.event_quantity <= 0):
        return False
    return (item.source_meals or "").startswith("event:")


def _has_user_investment(item: GroceryItem) -> bool:
    """Returns True when the user has explicitly modified this row in
    a way smart merge must preserve (overrides, check state). User-
    added rows are handled separately."""
    return (
        item.quantity_override is not None
        or item.unit_override is not None
        or item.notes_override is not None
        or item.is_checked
    )


def _apply_fresh_to_existing(item: GroceryItem, row: dict[str, Any]) -> None:
    """Refresh the auto-managed fields on an existing GroceryItem from a
    freshly aggregated row. Quantity / unit / notes are NOT touched
    when the user has set the corresponding override — the auto value
    stays in `total_quantity` / `unit` / `notes` (so iOS can show "you
    overrode 2 → 3 cups, system thinks 2 cups") but the override wins
    on display.
    """
    if item.quantity_override is None:
        item.total_quantity = row["total_quantity"]
    if item.unit_override is None:
        item.unit = row["unit"] or ""
    if item.notes_override is None:
        item.notes = row["notes"] or ""
    item.quantity_text = row["quantity_text"] or ""
    item.category = row["category"] or item.category
    item.source_meals = row["source_meals"] or ""
    item.review_flag = row["review_flag"] or ""
    # Refresh catalog-resolved metadata so a preference change picks up
    # the new variation.
    item.base_ingredient_id = row.get("base_ingredient_id")
    item.ingredient_variation_id = row.get("ingredient_variation_id")
    item.ingredient_name = row.get("ingredient_name") or item.ingredient_name
    item.normalized_name = row.get("normalized_name") or item.normalized_name
    item.resolution_status = row.get("resolution_status") or item.resolution_status


def _grocery_item_from_row(week_id: str, row: dict[str, Any]) -> GroceryItem:
    return GroceryItem(
        week_id=week_id,
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


def regenerate_grocery_for_week(session: Session, user_id: str, household_id: str, week: Week) -> list[GroceryItem]:
    """Smart-merge regeneration. Preserves user-added items, removed-
    item tombstones, override fields, household-shared check state,
    and event-merged contributions across meal changes. Pure auto
    rows whose meals were removed are deleted.

    M22.2: with `event_quantity` tracked separately, mixed week+event
    items can now have their `total_quantity` (week-meal portion)
    refreshed without disturbing the event contribution.
    """
    invalidate_week(session, week)

    existing = list(
        session.scalars(select(GroceryItem).where(GroceryItem.week_id == week.id)).all()
    )

    # Pure event-only rows are managed exclusively by
    # merge_event_into_week / unmerge_event_from_week. User-added
    # rows are similarly off-limits to the auto path.
    untouchable_keys: set[tuple[str, str, str, str]] = set()
    for item in existing:
        if item.is_user_added or _is_event_only(item):
            untouchable_keys.add(_key_for_item(item))

    eligible_by_key: dict[tuple[str, str, str, str], GroceryItem] = {}
    for item in existing:
        if item.is_user_added or _is_event_only(item):
            continue
        eligible_by_key[_key_for_item(item)] = item

    rows = build_grocery_rows_for_week(session, user_id, household_id, week)
    matched_keys: set[tuple[str, str, str, str]] = set()

    for row in rows:
        key = _key_for_row(row)
        if key in untouchable_keys:
            # An untouchable (event-only or user-added) row already
            # holds this slot. Skip duplication.
            continue
        existing_item = eligible_by_key.get(key)
        if existing_item is not None:
            matched_keys.add(key)
            if existing_item.is_user_removed:
                # Tombstone — leave as-is; iOS filter excludes it.
                continue
            _apply_fresh_to_existing(existing_item, row)
        else:
            session.add(_grocery_item_from_row(week.id, row))

    for key, item in eligible_by_key.items():
        if key in matched_keys:
            continue
        if item.is_user_removed:
            continue  # tombstone stays
        # An item with event_quantity but no fresh week-meal match:
        # drop the stale week portion but keep the event portion. The
        # event merge code is the only writer of event_quantity, so we
        # don't touch it.
        has_event_qty = item.event_quantity is not None and item.event_quantity > 0
        if has_event_qty:
            item.total_quantity = None
            item.review_flag = ""
            continue
        if _has_user_investment(item):
            if not item.review_flag:
                item.review_flag = "no longer in any meal"
            continue
        session.delete(item)

    session.flush()
    return list(
        session.scalars(select(GroceryItem).where(GroceryItem.week_id == week.id)).all()
    )


def add_user_grocery_item(
    session: Session,
    *,
    week: Week,
    name: str,
    quantity: float | None,
    unit: str,
    notes: str,
    category: str = "",
) -> GroceryItem:
    """Insert a manually-added grocery item on the week. Smart-merge
    regeneration never deletes or rewrites these rows.
    """
    invalidate_week(session, week)
    cleaned_name = name.strip()
    if not cleaned_name:
        raise ValueError("name required")
    item = GroceryItem(
        week_id=week.id,
        ingredient_name=cleaned_name,
        normalized_name=normalize_name(cleaned_name),
        total_quantity=quantity,
        unit=normalize_unit(unit) if unit else "",
        category=category or "",
        notes=notes or "",
        is_user_added=True,
    )
    session.add(item)
    session.flush()
    return item


def update_grocery_item(
    session: Session,
    *,
    week: Week,
    item: GroceryItem,
    fields: dict[str, Any],
) -> GroceryItem:
    """Patch a grocery item. Setting a value writes the override; passing
    a key with `None` clears the override (revert to auto). The `removed`
    pseudo-field flips `is_user_removed` (a soft-delete that survives
    smart-merge regeneration).
    """
    invalidate_week(session, week)
    if "quantity" in fields:
        if item.is_user_added:
            # User-added rows have no aggregated baseline, so we mutate
            # `total_quantity` directly.
            item.total_quantity = fields["quantity"]
        else:
            item.quantity_override = fields["quantity"]
    if "unit" in fields:
        if item.is_user_added:
            item.unit = normalize_unit(fields["unit"]) if fields["unit"] else ""
        else:
            value = fields["unit"]
            item.unit_override = normalize_unit(value) if value else None
    if "notes" in fields:
        if item.is_user_added:
            item.notes = fields["notes"] or ""
        else:
            item.notes_override = fields["notes"]
    if "category" in fields:
        item.category = fields["category"] or item.category
    if "name" in fields and item.is_user_added and fields["name"]:
        item.ingredient_name = str(fields["name"]).strip()
        item.normalized_name = normalize_name(item.ingredient_name)
    if "removed" in fields:
        item.is_user_removed = bool(fields["removed"])
    # M24+: catalog linking. Setting `base_ingredient_id` flips the
    # row to "locked" so smart-merge respects the link; passing
    # `None` unlinks (returns the row to "unresolved" so the auto
    # path can attempt to re-resolve next regen).
    if "base_ingredient_id" in fields:
        from app.models import BaseIngredient

        new_base_id = fields["base_ingredient_id"]
        if new_base_id:
            base = session.get(BaseIngredient, new_base_id)
            if base is None:
                raise ValueError("Base ingredient not found")
            item.base_ingredient_id = new_base_id
            item.resolution_status = "locked"
            # Refresh the canonical name + normalized form so future
            # smart-merge regen can match the same key.
            if not item.is_user_added:
                item.ingredient_name = base.name
            item.normalized_name = base.normalized_name or normalize_name(base.name)
            item.review_flag = ""
        else:
            item.base_ingredient_id = None
            item.ingredient_variation_id = None
            item.resolution_status = "unresolved"
    if "ingredient_variation_id" in fields:
        from app.models import IngredientVariation

        new_variation_id = fields["ingredient_variation_id"]
        if new_variation_id:
            variation = session.get(IngredientVariation, new_variation_id)
            if variation is None:
                raise ValueError("Ingredient variation not found")
            if item.base_ingredient_id and variation.base_ingredient_id != item.base_ingredient_id:
                raise ValueError("Variation belongs to a different base ingredient")
            item.ingredient_variation_id = new_variation_id
        else:
            item.ingredient_variation_id = None
    session.flush()
    return item


def set_grocery_item_checked(
    session: Session,
    *,
    week: Week,
    item: GroceryItem,
    user_id: str,
    checked: bool,
) -> GroceryItem:
    invalidate_week(session, week)
    item.is_checked = checked
    if checked:
        item.checked_at = datetime.now(timezone.utc)
        item.checked_by_user_id = user_id
    else:
        item.checked_at = None
        item.checked_by_user_id = None
    session.flush()
    return item
