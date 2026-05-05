"""M26 Phase 2: side-dish CRUD on `WeekMeal`.

A `WeekMealSide` is a named companion dish on a meal — a salad next
to a lasagna, garlic bread next to spaghetti. When linked to a
`Recipe`, the side's ingredients flow through grocery aggregation
just like the meal's main recipe (scaled by the parent meal's
`scale_multiplier`). Sides without a recipe link are informational
only and contribute nothing to the grocery list.

Each mutation regenerates grocery to keep the shopping list in sync
with the meal's true ingredient set. Smart-merge regen preserves
user investment (overrides, check state, user-added rows), so adding
or removing a side won't blow away anything the user has manually
edited on the grocery side.
"""
from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from app.models import Recipe, Week, WeekMeal, WeekMealSide
from app.services.grocery import regenerate_grocery_for_week
from app.services.weeks import invalidate_week


def _validate_recipe_id(session: Session, household_id: str, recipe_id: str | None) -> None:
    """Recipe must exist and belong to the caller's household. We don't
    leak whether a recipe exists across households — same 404 either
    way."""
    if recipe_id is None:
        return
    recipe = session.get(Recipe, recipe_id)
    if recipe is None or recipe.household_id != household_id:
        raise ValueError("Recipe not found")


def _next_sort_order(meal: WeekMeal) -> int:
    if not meal.sides:
        return 0
    return max(side.sort_order for side in meal.sides) + 1


def add_side(
    session: Session,
    *,
    week: Week,
    meal: WeekMeal,
    household_id: str,
    name: str,
    recipe_id: str | None = None,
    notes: str = "",
    sort_order: int | None = None,
    user_id: str,
) -> WeekMealSide:
    cleaned_name = (name or "").strip()
    if not cleaned_name:
        raise ValueError("name required")
    _validate_recipe_id(session, household_id, recipe_id)
    invalidate_week(session, week)
    side = WeekMealSide(
        week_meal_id=meal.id,
        recipe_id=recipe_id,
        name=cleaned_name,
        notes=notes or "",
        sort_order=_next_sort_order(meal) if sort_order is None else int(sort_order),
    )
    session.add(side)
    session.flush()
    regenerate_grocery_for_week(session, user_id, household_id, week)
    return side


def update_side(
    session: Session,
    *,
    week: Week,
    side: WeekMealSide,
    household_id: str,
    fields: dict[str, Any],
    user_id: str,
) -> WeekMealSide:
    """Patch a side. Mirrors `update_grocery_item`'s sentinel-by-presence
    pattern — only keys present in `fields` get applied. The
    `clear_recipe` pseudo-field nulls `recipe_id` (since `None` for
    `recipe_id` could ambiguously mean "leave alone" without an explicit
    sentinel).
    """
    if "name" in fields:
        cleaned = str(fields["name"] or "").strip()
        if not cleaned:
            raise ValueError("name cannot be empty")
        side.name = cleaned
    if fields.get("clear_recipe"):
        side.recipe_id = None
    elif "recipe_id" in fields and fields["recipe_id"] is not None:
        _validate_recipe_id(session, household_id, fields["recipe_id"])
        side.recipe_id = fields["recipe_id"]
    if "notes" in fields and fields["notes"] is not None:
        side.notes = fields["notes"]
    if "sort_order" in fields and fields["sort_order"] is not None:
        side.sort_order = int(fields["sort_order"])
    invalidate_week(session, week)
    session.flush()
    regenerate_grocery_for_week(session, user_id, household_id, week)
    return side


def delete_side(
    session: Session,
    *,
    week: Week,
    side: WeekMealSide,
    household_id: str,
    user_id: str,
) -> None:
    invalidate_week(session, week)
    session.delete(side)
    session.flush()
    regenerate_grocery_for_week(session, user_id, household_id, week)
