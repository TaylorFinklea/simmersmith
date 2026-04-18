"""Tests for ingredient macro extraction + the curated seed loader."""
from __future__ import annotations

from sqlalchemy import select

from app.db import session_scope
from app.models import BaseIngredient
from app.services.ingredient_ingest import _off_macros, _usda_macros
from app.services.nutrition import (
    calculate_meal_macros,
    ensure_ingredient_macros_seed,
    ingredient_macro_seed,
)


def _usda_food(**nutrients: float) -> dict:
    """Build a synthetic USDA food record with the given nutrient numbers."""
    items = [
        {"nutrientNumber": str(number), "value": value}
        for number, value in nutrients.items()
    ]
    return {"foodNutrients": items}


def test_usda_macros_extracts_all_five_nutrients() -> None:
    food = _usda_food(**{"208": 165, "203": 31, "204": 3.6, "205": 0, "291": 0})
    assert _usda_macros(food) == {
        "calories": 165.0,
        "protein_g": 31.0,
        "carbs_g": 0.0,
        "fat_g": 3.6,
        "fiber_g": 0.0,
    }


def test_usda_macros_returns_none_for_missing_nutrients() -> None:
    food = _usda_food(**{"208": 250})
    out = _usda_macros(food)
    assert out["calories"] == 250.0
    assert out["protein_g"] is None
    assert out["carbs_g"] is None
    assert out["fat_g"] is None
    assert out["fiber_g"] is None


def test_off_macros_reads_per_100g_fields() -> None:
    product = {
        "nutriments": {
            "energy-kcal_100g": 389,
            "proteins_100g": 17,
            "carbohydrates_100g": 66,
            "fat_100g": 7,
            "fiber_100g": 11,
        }
    }
    assert _off_macros(product) == {
        "calories": 389.0,
        "protein_g": 17.0,
        "carbs_g": 66.0,
        "fat_g": 7.0,
        "fiber_g": 11.0,
    }


def test_off_macros_falls_back_per_serving_when_per_100g_missing() -> None:
    product = {
        "nutriments": {
            "energy-kcal_serving": 250,
            "proteins_serving": 10,
        }
    }
    out = _off_macros(product)
    assert out["calories"] == 250.0
    assert out["protein_g"] == 10.0
    assert out["carbs_g"] is None


def test_macro_seed_populates_common_ingredients(client) -> None:
    """Seed defaults run in conftest — common ingredients should carry macros."""
    with session_scope() as session:
        chicken = session.scalar(
            select(BaseIngredient).where(BaseIngredient.normalized_name == "chicken breast")
        )
        assert chicken is not None
        assert chicken.calories == 165
        assert chicken.protein_g == 31
        assert chicken.fat_g == 3.6
        assert chicken.nutrition_reference_amount == 100.0
        assert chicken.nutrition_reference_unit == "g"


def test_macro_seed_does_not_overwrite_existing_macros(client) -> None:
    """If a base row already has macros (e.g. from USDA), the seed keeps them."""
    with session_scope() as session:
        chicken = session.scalar(
            select(BaseIngredient).where(BaseIngredient.normalized_name == "chicken breast")
        )
        assert chicken is not None
        chicken.protein_g = 99.9  # pretend USDA set this value earlier
        session.flush()

        # Re-run the seed; the explicit override should stand.
        ensure_ingredient_macros_seed(session)
        session.flush()
        session.refresh(chicken)
        assert chicken.protein_g == 99.9


def test_macro_seed_skips_metadata_entry() -> None:
    seed = ingredient_macro_seed()
    assert all(not entry.get("skip") for entry in seed)
    normalized_names = {entry.get("normalized_name") for entry in seed}
    assert "__metadata__" not in normalized_names
    # Sanity: at least 60 real ingredients shipped.
    assert len(seed) >= 60


def test_meal_macros_resolve_through_seed(client) -> None:
    """A meal with a base-ingredient id picks up seed macros end-to-end."""
    with session_scope() as session:
        chicken = session.scalar(
            select(BaseIngredient).where(BaseIngredient.normalized_name == "chicken breast")
        )
        assert chicken is not None

        # 200 g chicken breast → 2× per-100g reference.
        ingredients = [
            {
                "ingredient_name": "chicken breast",
                "normalized_name": "chicken breast",
                "base_ingredient_id": chicken.id,
                "ingredient_variation_id": None,
                "quantity": 200.0,
                "unit": "g",
            }
        ]
        macros = calculate_meal_macros(session, ingredients)

    assert macros.calories == 330.0          # 165 × 2
    assert macros.protein_g == 62.0          # 31 × 2
    assert round(macros.fat_g, 2) == 7.2     # 3.6 × 2
