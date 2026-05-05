"""M26 Phase 2 — `WeekMealSide` CRUD + grocery aggregation.

Each meal can carry zero-to-many sides; sides with a `recipe_id`
flow ingredients through grocery (scaled by the parent meal's
`scale_multiplier`); sides without a recipe contribute nothing.
"""
from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import WeekMeal, WeekMealSide
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.sides import add_side, delete_side, update_side
from app.services.weeks import create_or_get_week, get_week

_uid = get_settings().local_user_id


def _build_week_with_one_meal(session, *, week_start: date, recipe_extra: list[RecipePayload] | None = None):
    week = create_or_get_week(
        session,
        user_id=_uid,
        household_id=_uid,
        week_start=week_start,
        notes="sides test week",
    )
    recipes = [
        RecipePayload(
            recipe_id="lasagna",
            name="Lasagna",
            meal_type="dinner",
            servings=4,
            ingredients=[
                RecipeIngredientPayload(ingredient_name="Lasagna noodles", quantity=1, unit="lb"),
                RecipeIngredientPayload(ingredient_name="Ground beef", quantity=1, unit="lb"),
            ],
        ),
    ]
    if recipe_extra:
        recipes.extend(recipe_extra)
    payload = DraftFromAIRequest(
        prompt="dinner with possible sides",
        recipes=recipes,
        meal_plan=[
            MealDraftPayload(
                day_name="Wednesday",
                meal_date=week_start,
                slot="dinner",
                recipe_id="lasagna",
                recipe_name="Lasagna",
                servings=4,
            ),
        ],
    )
    apply_ai_draft(session, week, payload)
    meal = session.scalar(select(WeekMeal).where(WeekMeal.week_id == week.id))
    return week, meal


def test_side_with_linked_recipe_flows_into_grocery() -> None:
    """A side with a `recipe_id` aggregates exactly like a recipe-
    backed meal — its ingredients land on the grocery list scaled by
    the parent meal's scale_multiplier."""
    with session_scope() as session:
        week, meal = _build_week_with_one_meal(
            session,
            week_start=date(2026, 5, 6),
            recipe_extra=[
                RecipePayload(
                    recipe_id="garlic-bread",
                    name="Garlic bread",
                    meal_type="side",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Baguette", quantity=1, unit="ea"),
                        RecipeIngredientPayload(ingredient_name="Garlic", quantity=4, unit="clove"),
                    ],
                ),
            ],
        )
        add_side(
            session,
            week=week,
            meal=meal,
            household_id=_uid,
            name="Garlic bread",
            recipe_id="garlic-bread",
            user_id=_uid,
        )
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    names = {item.ingredient_name for item in refreshed.grocery_items}
    assert "Baguette" in names
    assert "Garlic" in names
    # The side's source label includes "[side: <name>]" so the user
    # can trace the row back to its origin.
    baguette = next(i for i in refreshed.grocery_items if i.ingredient_name == "Baguette")
    assert "[side: Garlic bread]" in baguette.source_meals
    # The parent meal's ingredients are still there too.
    assert "Lasagna noodles" in names


def test_side_without_recipe_contributes_nothing_to_grocery() -> None:
    """A free-text side (no `recipe_id`) is informational only; it
    must not produce grocery rows."""
    with session_scope() as session:
        week, meal = _build_week_with_one_meal(session, week_start=date(2026, 5, 13))
        baseline_before = {item.id for item in week.grocery_items}
        add_side(
            session,
            week=week,
            meal=meal,
            household_id=_uid,
            name="Caesar salad",
            recipe_id=None,
            user_id=_uid,
        )
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    baseline_after = {item.id for item in refreshed.grocery_items}
    assert baseline_after == baseline_before  # no new grocery rows


def test_side_scale_multiplier_propagates() -> None:
    """When the parent meal has scale_multiplier=2, the side recipe's
    quantities double on the grocery list."""
    with session_scope() as session:
        week, meal = _build_week_with_one_meal(
            session,
            week_start=date(2026, 5, 20),
            recipe_extra=[
                RecipePayload(
                    recipe_id="rice",
                    name="Rice",
                    meal_type="side",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="White rice", quantity=2, unit="cup"),
                    ],
                ),
            ],
        )
        meal.scale_multiplier = 2.0
        session.flush()
        add_side(
            session,
            week=week,
            meal=meal,
            household_id=_uid,
            name="Rice",
            recipe_id="rice",
            user_id=_uid,
        )
        refreshed = get_week(session, _uid, week.id)

    rice = next(
        (i for i in refreshed.grocery_items if "rice" in i.normalized_name.lower()),
        None,
    )
    assert rice is not None, f"no rice in grocery; saw {[i.ingredient_name for i in refreshed.grocery_items]}"
    assert rice.total_quantity == 4.0  # 2 cups * 2x
    assert rice.unit == "cup"


def test_side_update_and_delete_round_trip() -> None:
    """Editing a side's recipe link refreshes grocery; deleting the
    side removes its contribution."""
    with session_scope() as session:
        week, meal = _build_week_with_one_meal(
            session,
            week_start=date(2026, 5, 27),
            recipe_extra=[
                RecipePayload(
                    recipe_id="caesar",
                    name="Caesar salad",
                    meal_type="side",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Romaine lettuce", quantity=2, unit="ea"),
                    ],
                ),
                RecipePayload(
                    recipe_id="green-salad",
                    name="Green salad",
                    meal_type="side",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Mixed greens", quantity=1, unit="bag"),
                    ],
                ),
            ],
        )
        from app.models import GroceryItem

        side = add_side(
            session,
            week=week,
            meal=meal,
            household_id=_uid,
            name="Salad",
            recipe_id="caesar",
            user_id=_uid,
        )
        side_id = side.id
        # Romaine should be on the grocery list at this point.
        assert any(i.ingredient_name == "Romaine lettuce" for i in week.grocery_items)

        # Swap the linked recipe → grocery should swap too.
        update_side(
            session,
            week=week,
            side=side,
            household_id=_uid,
            fields={"recipe_id": "green-salad"},
            user_id=_uid,
        )
        # Direct DB query — bypasses the ORM identity-map cache that
        # would otherwise return the original `week.grocery_items` set
        # (the API endpoint achieves the same via `session.expire_all()`
        # after commit).
        live = session.scalars(
            select(GroceryItem).where(
                GroceryItem.week_id == week.id, GroceryItem.is_user_removed.is_(False)
            )
        ).all()
        names = {item.ingredient_name for item in live}
        assert "Mixed greens" in names, names
        assert "Romaine lettuce" not in names, names

        # Delete the side entirely → grocery contribution disappears.
        side_to_delete = session.get(WeekMealSide, side_id)
        assert side_to_delete is not None
        delete_side(
            session,
            week=week,
            side=side_to_delete,
            household_id=_uid,
            user_id=_uid,
        )
        live2 = session.scalars(
            select(GroceryItem).where(
                GroceryItem.week_id == week.id, GroceryItem.is_user_removed.is_(False)
            )
        ).all()
        live_names = {item.ingredient_name for item in live2}
        assert "Mixed greens" not in live_names


def test_side_meal_cascade_delete() -> None:
    """Removing a meal from `week.meals` ORM-cascades the deletion to
    its sides (`cascade='all, delete-orphan'` on both relationships)."""
    with session_scope() as session:
        week, meal = _build_week_with_one_meal(session, week_start=date(2026, 6, 3))
        side = add_side(
            session,
            week=week,
            meal=meal,
            household_id=_uid,
            name="Coleslaw",
            recipe_id=None,
            user_id=_uid,
        )
        side_id = side.id
        meal_id = meal.id
        # Pre-flight: confirm the side actually persisted with the
        # right FK before we test the cascade.
        side_check = session.scalars(
            select(WeekMealSide).where(WeekMealSide.id == side_id)
        ).all()
        assert side_check and side_check[0].week_meal_id == meal_id, (
            f"side not persisted with meal_id; got {side_check}"
        )
        # Refresh the meal so its `sides` relationship reflects the
        # new row, then remove it from the week (orphan-cascade) and
        # flush.
        session.refresh(meal)
        sides_seen = list(meal.sides)
        week.meals.remove(meal)
        session.flush()
        meal_rows = session.scalars(
            select(WeekMeal).where(WeekMeal.id == meal_id)
        ).all()
        rows = session.scalars(
            select(WeekMealSide).where(WeekMealSide.id == side_id)
        ).all()

    assert not meal_rows, f"meal still present: {meal_rows}"
    assert not rows, f"sides materialized: {sides_seen}, side rows: {rows}"
