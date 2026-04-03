from __future__ import annotations

from app.db import session_scope
from app.models import BaseIngredient
from app.services.ingredient_catalog import ensure_base_ingredient
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
