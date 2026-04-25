"""Tests for the difficulty inference path on /api/recipes (M12 Phase 2).

Verifies the migration applies cleanly (the autouse `reset_database`
fixture would fail otherwise), the opportunistic AI inference fires
when both fields are unset, and an AI failure does NOT block the save.
"""
from __future__ import annotations

from unittest.mock import patch

from app.services.recipe_difficulty_ai import DifficultyAssessment


def _payload_with_ingredient(name: str = "Pancakes") -> dict:
    return {
        "name": name,
        "meal_type": "breakfast",
        "cuisine": "American",
        "servings": 2.0,
        "ingredients": [
            {
                "ingredient_name": "flour",
                "quantity": 1.0,
                "unit": "cup",
            }
        ],
        "steps": [
            {"step_number": 0, "instruction": "Mix everything."},
            {"step_number": 1, "instruction": "Cook on a hot pan."},
        ],
    }


def test_difficulty_inference_runs_on_first_save(client) -> None:
    fake = DifficultyAssessment(score=2, kid_friendly=True, reason="Simple mix-and-cook.")
    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        return_value=fake,
    ) as mock_infer:
        response = client.post("/api/recipes", json=_payload_with_ingredient())

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["difficulty_score"] == 2
    assert payload["kid_friendly"] is True
    mock_infer.assert_called_once()


def test_difficulty_inference_skipped_when_score_already_set(client) -> None:
    payload = _payload_with_ingredient()
    payload["difficulty_score"] = 3
    payload["kid_friendly"] = False
    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty"
    ) as mock_infer:
        response = client.post("/api/recipes", json=payload)

    assert response.status_code == 200
    body = response.json()
    assert body["difficulty_score"] == 3
    mock_infer.assert_not_called()


def test_difficulty_inference_failure_does_not_block_save(client) -> None:
    """If AI is offline / errors, the save still succeeds. Score stays NULL."""
    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty",
        side_effect=RuntimeError("No direct AI provider is configured."),
    ):
        response = client.post("/api/recipes", json=_payload_with_ingredient())

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["difficulty_score"] is None
    assert body["kid_friendly"] is False


def test_difficulty_inference_skipped_when_no_ingredients(client) -> None:
    """Ingredient-less recipe has nothing for the AI to score."""
    with patch(
        "app.services.recipe_difficulty_ai.infer_recipe_difficulty"
    ) as mock_infer:
        response = client.post(
            "/api/recipes",
            json={
                "name": "Empty stub",
                "meal_type": "dinner",
                "cuisine": "",
                "servings": 1.0,
                "ingredients": [],
                "steps": [],
            },
        )

    assert response.status_code == 200, response.text
    mock_infer.assert_not_called()
