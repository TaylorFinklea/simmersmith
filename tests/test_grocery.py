from __future__ import annotations

from datetime import date

from app.config import get_settings
from app.db import session_scope
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.ingredient_catalog import create_or_update_variation, ensure_base_ingredient, upsert_ingredient_preference
from app.services.weeks import create_or_get_week, get_week

_uid = get_settings().local_user_id


def test_grocery_aggregation_excludes_default_staples() -> None:
    with session_scope() as session:
        week = create_or_get_week(session, _uid, date(2026, 3, 16), "test week")
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
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.ingredient_name == "Chicken thighs"
    assert item.total_quantity == 3.0
    assert item.unit == "lb"


def test_inline_meal_ingredients_flow_into_grocery_rows() -> None:
    with session_scope() as session:
        week = create_or_get_week(session, _uid, date(2026, 3, 23), "inline ingredients")
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
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert {item.ingredient_name for item in refreshed.grocery_items} == {"Apples", "Cheddar"}


def test_grocery_resolution_prefers_structured_variation_for_base_ingredient() -> None:
    with session_scope() as session:
        biscuits = ensure_base_ingredient(
            session,
            name="Refrigerated biscuits",
            normalized_name="refrigerated biscuits",
            category="Refrigerated",
            default_unit="can",
        )
        pillsbury = create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Pillsbury refrigerated biscuits",
            brand="Pillsbury",
            package_size_unit="can",
            calories=150,
            nutrition_reference_amount=1,
            nutrition_reference_unit="ea",
        )
        upsert_ingredient_preference(
            session,
            _uid,
            base_ingredient_id=biscuits.id,
            preferred_variation_id=pillsbury.id,
            choice_mode="preferred",
        )

        week = create_or_get_week(session, _uid, date(2026, 3, 30), "biscuits preference")
        payload = DraftFromAIRequest(
            prompt="Breakfast test",
            recipes=[
                RecipePayload(
                    recipe_id="biscuit-breakfast",
                    name="Biscuit Breakfast",
                    meal_type="breakfast",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="refrigerated biscuits",
                            quantity=1,
                            unit="can",
                            category="Refrigerated",
                        )
                    ],
                )
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Tuesday",
                    meal_date=date(2026, 3, 31),
                    slot="breakfast",
                    recipe_id="biscuit-breakfast",
                    recipe_name="Biscuit Breakfast",
                    servings=4,
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.base_ingredient_id == biscuits.id
    assert item.ingredient_variation_id == pillsbury.id
    assert item.ingredient_name == "Pillsbury refrigerated biscuits"
    assert item.resolution_status == "resolved"


def test_grocery_resolution_keeps_inferred_exact_variation_match_as_suggested() -> None:
    with session_scope() as session:
        biscuits = ensure_base_ingredient(
            session,
            name="Refrigerated biscuits",
            normalized_name="refrigerated biscuits",
            category="Refrigerated",
            default_unit="can",
        )
        pillsbury = create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Pillsbury refrigerated biscuits",
            brand="Pillsbury",
            package_size_unit="can",
            calories=150,
            nutrition_reference_amount=1,
            nutrition_reference_unit="ea",
        )

        week = create_or_get_week(session, _uid, date(2026, 4, 6), "inferred variation suggestion")
        payload = DraftFromAIRequest(
            prompt="Breakfast test",
            recipes=[
                RecipePayload(
                    recipe_id="brand-biscuits",
                    name="Brand Biscuits",
                    meal_type="breakfast",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="Pillsbury refrigerated biscuits",
                            quantity=1,
                            unit="can",
                            category="Refrigerated",
                        )
                    ],
                )
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 4, 6),
                    slot="breakfast",
                    recipe_id="brand-biscuits",
                    recipe_name="Brand Biscuits",
                    servings=4,
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.base_ingredient_id == biscuits.id
    assert item.ingredient_variation_id == pillsbury.id
    assert item.ingredient_name == "Pillsbury refrigerated biscuits"
    assert item.resolution_status == "suggested"


def test_grocery_resolution_prefers_household_brand_match_when_recipe_stays_generic() -> None:
    with session_scope() as session:
        biscuits = ensure_base_ingredient(
            session,
            name="Refrigerated biscuits",
            normalized_name="refrigerated biscuits",
            category="Refrigerated",
            default_unit="can",
        )
        pillsbury = create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Pillsbury refrigerated biscuits",
            brand="Pillsbury",
            package_size_unit="can",
        )
        create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Store brand refrigerated biscuits",
            brand="Great Value",
            package_size_unit="can",
        )
        upsert_ingredient_preference(
            session,
            _uid,
            base_ingredient_id=biscuits.id,
            preferred_brand="Pillsbury",
            choice_mode="preferred",
        )

        week = create_or_get_week(session, _uid, date(2026, 4, 13), "brand preference fallback")
        payload = DraftFromAIRequest(
            prompt="Breakfast test",
            recipes=[
                RecipePayload(
                    recipe_id="brand-preference-biscuits",
                    name="Brand Preference Biscuits",
                    meal_type="breakfast",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="refrigerated biscuits",
                            quantity=1,
                            unit="can",
                            category="Refrigerated",
                        )
                    ],
                )
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 4, 13),
                    slot="breakfast",
                    recipe_id="brand-preference-biscuits",
                    recipe_name="Brand Preference Biscuits",
                    servings=4,
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.base_ingredient_id == biscuits.id
    assert item.ingredient_variation_id == pillsbury.id
    assert item.ingredient_name == "Pillsbury refrigerated biscuits"
    assert item.resolution_status == "resolved"


def test_grocery_locked_recipe_variation_beats_household_preference() -> None:
    with session_scope() as session:
        biscuits = ensure_base_ingredient(
            session,
            name="Refrigerated biscuits",
            normalized_name="refrigerated biscuits",
            category="Refrigerated",
            default_unit="can",
        )
        pillsbury = create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Pillsbury refrigerated biscuits",
            brand="Pillsbury",
            package_size_unit="can",
        )
        store_brand = create_or_update_variation(
            session,
            base_ingredient_id=biscuits.id,
            name="Store brand refrigerated biscuits",
            brand="Great Value",
            package_size_unit="can",
        )
        upsert_ingredient_preference(
            session,
            _uid,
            base_ingredient_id=biscuits.id,
            preferred_variation_id=pillsbury.id,
            choice_mode="preferred",
        )

        week = create_or_get_week(session, _uid, date(2026, 4, 20), "locked variation precedence")
        payload = DraftFromAIRequest(
            prompt="Breakfast test",
            recipes=[
                RecipePayload(
                    recipe_id="locked-brand-biscuits",
                    name="Locked Brand Biscuits",
                    meal_type="breakfast",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(
                            ingredient_name="Store brand refrigerated biscuits",
                            quantity=1,
                            unit="can",
                            category="Refrigerated",
                            base_ingredient_id=biscuits.id,
                            ingredient_variation_id=store_brand.id,
                            resolution_status="locked",
                        )
                    ],
                )
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 4, 20),
                    slot="breakfast",
                    recipe_id="locked-brand-biscuits",
                    recipe_name="Locked Brand Biscuits",
                    servings=4,
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, _uid, week.id)

    assert refreshed is not None
    assert len(refreshed.grocery_items) == 1
    item = refreshed.grocery_items[0]
    assert item.base_ingredient_id == biscuits.id
    assert item.ingredient_variation_id == store_brand.id
    assert item.ingredient_name == "Store brand refrigerated biscuits"
    assert item.resolution_status == "locked"
