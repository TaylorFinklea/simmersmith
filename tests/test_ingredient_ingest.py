from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import (
    BaseIngredient,
    GroceryItem,
    IngredientPreference,
    IngredientVariation,
    Recipe,
    RecipeIngredient,
    Week,
    WeekMeal,
    WeekMealIngredient,
)
from app.services.ingredient_catalog import (
    apply_product_like_base_rewrites,
    create_or_update_variation,
    ensure_base_ingredient,
    is_product_like_base_ingredient,
    normalize_product_like_base_ingredients,
    plan_product_like_base_rewrites,
    upsert_ingredient_preference,
)
from app.services.ingredient_ingest import ingest_usda_terms, prune_usda_seed_rows


def test_usda_ingest_creates_curated_base_ingredient_per_seed_term(monkeypatch) -> None:
    def fake_fetch_json(url: str, *, payload=None, headers=None) -> dict[str, object]:
        assert payload is not None
        if payload["query"] == "yellow mustard":
            return {
                "foods": [
                    {
                        "fdcId": 326698,
                        "description": "Mustard, prepared, yellow",
                        "foodCategory": "Spices and Herbs",
                        "foodNutrients": [{"nutrientNumber": "208", "value": 61}],
                    },
                    {
                        "fdcId": 2710233,
                        "description": "Honey mustard dressing, fat free",
                        "foodCategory": "Salad dressings and vegetable oils",
                        "foodNutrients": [{"nutrientNumber": "208", "value": 169}],
                    },
                    {
                        "fdcId": 2709606,
                        "description": "Mustard greens, raw",
                        "foodCategory": "Other dark green vegetables",
                        "foodNutrients": [{"nutrientNumber": "208", "value": 27}],
                    },
                ]
            }
        return {"foods": []}

    monkeypatch.setattr("app.services.ingredient_ingest._fetch_json", fake_fetch_json)

    with session_scope() as session:
        result = ingest_usda_terms(session, api_key="test", terms=["yellow mustard"])
        session.commit()

        rows = session.query(BaseIngredient).filter(BaseIngredient.source_name == "USDA FoodData Central").all()
        assert result.bases_created_or_updated == 1
        assert len(rows) == 1
        assert rows[0].name == "Yellow mustard"
        assert rows[0].normalized_name == "yellow mustard"
        assert rows[0].source_record_id == "326698"
        assert rows[0].calories == 61


def test_prune_usda_seed_rows_archives_noise_but_preserves_curated_terms() -> None:
    with session_scope() as session:
        keep = ensure_base_ingredient(
            session,
            name="Yellow mustard",
            normalized_name="yellow mustard",
            source_name="USDA FoodData Central",
            source_record_id="326698",
        )
        archive = ensure_base_ingredient(
            session,
            name="Bacon biscuit sandwich",
            normalized_name="bacon biscuit sandwich",
            source_name="USDA FoodData Central",
            source_record_id="2707337",
        )
        session.commit()

        archived_count = prune_usda_seed_rows(session, allowed_terms=["yellow mustard"])
        session.commit()

        kept_row = session.get(BaseIngredient, keep.id)
        archived_row = session.get(BaseIngredient, archive.id)
        assert archived_count == 1
        assert kept_row is not None and kept_row.archived_at is None and kept_row.active is True
        assert archived_row is not None and archived_row.archived_at is not None and archived_row.active is False


def test_normalize_product_like_base_ingredients_merges_into_clean_generic_base() -> None:
    with session_scope() as session:
        source = ensure_base_ingredient(
            session,
            name="1 can refrigerated biscuits",
            normalized_name="1 can refrigerated biscuits",
        )
        target = ensure_base_ingredient(
            session,
            name="Refrigerated biscuits",
            normalized_name="refrigerated biscuits",
        )
        variation = create_or_update_variation(
            session,
            base_ingredient_id=source.id,
            name="Pillsbury Grands Biscuits",
            normalized_name="pillsbury grands biscuits",
            brand="Pillsbury",
        )
        session.commit()

        normalized_count = normalize_product_like_base_ingredients(session)
        session.commit()

        assert normalized_count == 1
        merged_source = session.get(BaseIngredient, source.id)
        merged_target = session.get(BaseIngredient, target.id)
        moved_variation = session.get(IngredientVariation, variation.id)
        assert merged_source is not None and merged_source.merged_into_id == target.id
        assert merged_source.archived_at is not None and merged_source.active is False
        assert merged_target is not None and merged_target.archived_at is None and merged_target.active is True
        assert moved_variation is not None and moved_variation.base_ingredient_id == target.id


def test_is_product_like_base_ingredient_flags_packaging_suffixes() -> None:
    with session_scope() as session:
        mustard = ensure_base_ingredient(
            session,
            name="French Chestnut Mustard Jar",
            normalized_name="french chestnut mustard jar",
            source_name="Open Food Facts",
            source_record_id="mustard-jar",
        )
        session.commit()

        loaded = session.get(BaseIngredient, mustard.id)
        assert loaded is not None
        assert is_product_like_base_ingredient(loaded) is True


def test_product_like_rewrite_creates_suggested_variation_and_repoints_usage() -> None:
    with session_scope() as session:
        generic = ensure_base_ingredient(
            session,
            name="Yellow mustard",
            normalized_name="yellow mustard",
            category="Condiments",
            source_name="USDA FoodData Central",
            source_record_id="326698",
        )
        source = ensure_base_ingredient(
            session,
            name="Classic Yellow Mustard",
            normalized_name="classic yellow mustard",
            category="Condiments",
            source_name="Open Food Facts",
            source_record_id="0123456789",
        )
        upsert_ingredient_preference(session, get_settings().local_user_id, base_ingredient_id=source.id, choice_mode="preferred")

        recipe = Recipe(id="mustard-recipe", name="Mustard Sauce", user_id=get_settings().local_user_id)
        session.add(recipe)
        session.add(
            RecipeIngredient(
                id="mustard-recipe-ingredient-1",
                recipe_id=recipe.id,
                ingredient_name="Classic Yellow Mustard",
                normalized_name="classic yellow mustard",
                quantity=1,
                unit="jar",
                category="Condiments",
                base_ingredient_id=source.id,
                resolution_status="resolved",
            )
        )

        week = Week(
            user_id=get_settings().local_user_id,
            week_start=date(2026, 4, 6),
            week_end=date(2026, 4, 12),
            notes="rewrite",
        )
        session.add(week)
        session.flush()
        meal = WeekMeal(
            week_id=week.id,
            day_name="Monday",
            meal_date=date(2026, 4, 6),
            slot="dinner",
            recipe_name="Mustard Sauce",
        )
        session.add(meal)
        session.flush()
        session.add(
            WeekMealIngredient(
                id=f"{meal.id}-ingredient-1",
                week_meal_id=meal.id,
                ingredient_name="Classic Yellow Mustard",
                normalized_name="classic yellow mustard",
                quantity=1,
                unit="jar",
                category="Condiments",
                base_ingredient_id=source.id,
                resolution_status="resolved",
            )
        )
        grocery = GroceryItem(
            week_id=week.id,
            ingredient_name="Classic Yellow Mustard",
            normalized_name="classic yellow mustard",
            total_quantity=1,
            unit="jar",
            category="Condiments",
            source_meals="Monday dinner",
            base_ingredient_id=source.id,
            resolution_status="resolved",
        )
        session.add(grocery)
        session.commit()

        plans = plan_product_like_base_rewrites(session)
        result = apply_product_like_base_rewrites(session, plans=plans)
        session.commit()

        assert result.merged_count == 1
        assert result.variation_created_count == 1
        rewritten_source = session.get(BaseIngredient, source.id)
        rewritten_generic = session.get(BaseIngredient, generic.id)
        assert rewritten_source is not None and rewritten_source.merged_into_id == generic.id
        assert rewritten_generic is not None and rewritten_generic.archived_at is None
        variation = session.scalar(
            session.query(IngredientVariation).filter(IngredientVariation.base_ingredient_id == generic.id).statement
        )
        assert variation is not None
        assert variation.normalized_name == "classic yellow mustard"

        recipe_ingredient = session.get(RecipeIngredient, "mustard-recipe-ingredient-1")
        assert recipe_ingredient is not None
        assert recipe_ingredient.base_ingredient_id == generic.id
        assert recipe_ingredient.ingredient_variation_id == variation.id
        assert recipe_ingredient.resolution_status == "suggested"

        inline_ingredient = session.get(WeekMealIngredient, f"{meal.id}-ingredient-1")
        assert inline_ingredient is not None
        assert inline_ingredient.base_ingredient_id == generic.id
        assert inline_ingredient.ingredient_variation_id == variation.id
        assert inline_ingredient.resolution_status == "suggested"

        rewritten_grocery = session.get(GroceryItem, grocery.id)
        assert rewritten_grocery is not None
        assert rewritten_grocery.base_ingredient_id == generic.id
        assert rewritten_grocery.ingredient_variation_id == variation.id
        assert rewritten_grocery.resolution_status == "suggested"

        preference = session.scalar(select(IngredientPreference).where(IngredientPreference.base_ingredient_id == generic.id))
        assert preference is not None
        assert preference.preferred_variation_id == variation.id

        rerun = apply_product_like_base_rewrites(session)
        assert rerun.merged_count == 0
