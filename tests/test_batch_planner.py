"""Planner lane — bug bash 2026-06-13.

#55 score_macro_drift always returned no flags. It summed per-day calories
from each meal_plan entry's `ingredients`, but generate_week_plan defaults
those to `[]` and the AI only puts ingredients on the `recipes` array. The
fix resolves each meal_plan entry to its recipe (by `recipe_name`) and sums
that recipe's ingredients, so the "Days off calorie target" feedback is no
longer dead.
"""
from __future__ import annotations

from app.config import get_settings
from app.db import session_scope
from app.schemas.profile import DietaryGoalPayload
from app.services.nutrition import MacroBreakdown
from app.services.profile import upsert_dietary_goal
from app.services.week_planner import score_macro_drift


def _fake_macros_from_ingredients(_session, ingredients):
    """Stand-in for calculate_meal_macros: 400 kcal per ingredient.

    The point of the fix is *which* ingredients reach this call. Pre-fix the
    function always passed the empty meal-level list (-> is_empty -> skipped);
    post-fix it passes the resolved recipe's ingredients.
    """
    return MacroBreakdown(calories=400.0 * len(ingredients))


def _set_goal(user_id: str, daily_calories: int) -> None:
    with session_scope() as session:
        upsert_dietary_goal(
            session,
            user_id,
            DietaryGoalPayload(
                goal_type="maintain",
                daily_calories=daily_calories,
                protein_g=150,
                carbs_g=200,
                fat_g=60,
            ),
        )


def _plan(meal_ingredients_count: int) -> dict:
    """A one-day plan: 3 meals, each pointing at a recipe carrying N ingredients.

    Meal-level `ingredients` stay `[]` exactly as generate_week_plan leaves them.
    """
    recipe_ingredients = [
        {"ingredient_name": f"ing-{i}", "quantity": 1, "unit": "cup"}
        for i in range(meal_ingredients_count)
    ]
    return {
        "recipes": [
            {"name": "Breakfast Bowl", "ingredients": list(recipe_ingredients)},
            {"name": "Lunch Wrap", "ingredients": list(recipe_ingredients)},
            {"name": "Dinner Plate", "ingredients": list(recipe_ingredients)},
        ],
        "meal_plan": [
            {"day_name": "Monday", "meal_date": "2026-09-21", "slot": "breakfast", "recipe_name": "Breakfast Bowl", "ingredients": []},
            {"day_name": "Monday", "meal_date": "2026-09-21", "slot": "lunch", "recipe_name": "Lunch Wrap", "ingredients": []},
            {"day_name": "Monday", "meal_date": "2026-09-21", "slot": "dinner", "recipe_name": "Dinner Plate", "ingredients": []},
        ],
    }


def test_macro_drift_flags_day_off_target(monkeypatch) -> None:
    """Pre-fix this always returned [] (meal-level ingredients are []); now the
    recipe ingredients are resolved and a way-over-target day is flagged."""
    user_id = get_settings().local_user_id
    _set_goal(user_id, 1200)
    monkeypatch.setattr("app.services.nutrition.calculate_meal_macros",_fake_macros_from_ingredients)

    # 3 meals * 2 ingredients * 400 kcal = 2400 kcal vs 1200 target -> +100% drift.
    plan = _plan(meal_ingredients_count=2)
    with session_scope() as session:
        flags = score_macro_drift(session, plan, user_id)

    assert len(flags) == 1
    flag = flags[0]
    assert flag["meal_date"] == "2026-09-21"
    assert flag["day_name"] == "Monday"
    assert flag["calories"] == 2400.0
    assert flag["target"] == 1200
    assert flag["drift_pct"] == 100.0


def test_macro_drift_no_flag_when_on_target(monkeypatch) -> None:
    """A day whose resolved-recipe calories land near target produces no flag."""
    user_id = get_settings().local_user_id
    _set_goal(user_id, 2400)
    monkeypatch.setattr("app.services.nutrition.calculate_meal_macros",_fake_macros_from_ingredients)

    # 3 meals * 2 ingredients * 400 = 2400 kcal == 2400 target -> 0% drift.
    plan = _plan(meal_ingredients_count=2)
    with session_scope() as session:
        flags = score_macro_drift(session, plan, user_id)

    assert flags == []


def test_macro_drift_uses_recipe_not_empty_meal_ingredients(monkeypatch) -> None:
    """Regression guard: the empty meal-level `ingredients` must NOT be what
    reaches calculate_meal_macros — the recipe's ingredients must."""
    user_id = get_settings().local_user_id
    _set_goal(user_id, 1200)

    seen: list[int] = []

    def _spy(_session, ingredients):
        seen.append(len(ingredients))
        return MacroBreakdown(calories=400.0 * len(ingredients))

    monkeypatch.setattr("app.services.nutrition.calculate_meal_macros",_spy)

    plan = _plan(meal_ingredients_count=3)
    with session_scope() as session:
        score_macro_drift(session, plan, user_id)

    # Every meal must have been fed the 3-ingredient recipe list, never [].
    assert seen == [3, 3, 3]


def test_macro_drift_empty_when_no_goal(monkeypatch) -> None:
    """No dietary goal -> always [] (absence of flags is not 'on target')."""
    user_id = get_settings().local_user_id
    monkeypatch.setattr("app.services.nutrition.calculate_meal_macros",_fake_macros_from_ingredients)

    plan = _plan(meal_ingredients_count=2)
    with session_scope() as session:
        flags = score_macro_drift(session, plan, user_id)

    assert flags == []
