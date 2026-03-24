from __future__ import annotations

from datetime import date

from app.db import session_scope
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.weeks import create_or_get_week, get_week


def test_grocery_aggregation_excludes_default_staples() -> None:
    with session_scope() as session:
        week = create_or_get_week(session, date(2026, 3, 16), "test week")
        payload = DraftFromAIRequest(
            prompt="Build a simple protein-focused week.",
            recipes=[
                RecipePayload(
                    recipe_id="sheet-pan-chicken",
                    name="Sheet Pan Chicken",
                    meal_type="dinner",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Chicken thighs", quantity=2, unit="lb"),
                        RecipeIngredientPayload(ingredient_name="Olive oil", quantity=2, unit="tbsp"),
                    ],
                ),
                RecipePayload(
                    recipe_id="chicken-salad-wraps",
                    name="Chicken Salad Wraps",
                    meal_type="lunch",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Chicken thighs", quantity=1, unit="lb"),
                        RecipeIngredientPayload(ingredient_name="Black pepper", quantity=1, unit="tsp"),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 3, 16),
                    slot="dinner",
                    recipe_id="sheet-pan-chicken",
                    recipe_name="Sheet Pan Chicken",
                    servings=4,
                ),
                MealDraftPayload(
                    day_name="Tuesday",
                    meal_date=date(2026, 3, 17),
                    slot="lunch",
                    recipe_id="chicken-salad-wraps",
                    recipe_name="Chicken Salad Wraps",
                    servings=4,
                ),
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.ingredient_name == "Chicken thighs"
    assert item.total_quantity == 3.0
    assert item.unit == "lb"


def test_inline_meal_ingredients_flow_into_grocery_rows() -> None:
    with session_scope() as session:
        week = create_or_get_week(session, date(2026, 3, 23), "inline ingredients")
        payload = DraftFromAIRequest(
            prompt="Ad hoc lunches only.",
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 3, 23),
                    slot="lunch",
                    recipe_name="Fruit Plate",
                    servings=2,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Apples", quantity=4, unit="ea"),
                        RecipeIngredientPayload(ingredient_name="Cheddar", quantity=8, unit="oz"),
                    ],
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, week.id)

    assert refreshed is not None
    assert {item.ingredient_name for item in refreshed.grocery_items} == {"Apples", "Cheddar"}
