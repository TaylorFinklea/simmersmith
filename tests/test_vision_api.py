"""Integration tests for /api/vision/* routes."""
from __future__ import annotations

import base64
from unittest.mock import patch

from app.services.vision_ai import IngredientIdentification


def _png_bytes() -> bytes:
    # 1x1 transparent PNG. Real bytes so request validation passes.
    return base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )


def test_identify_ingredient_route_returns_structured(client) -> None:
    fake_result = IngredientIdentification(
        name="habanero pepper",
        confidence="high",
        common_names=["habanero"],
        cuisine_uses=[],
        recipe_match_terms=["chili pepper", "habanero"],
        notes="Very spicy.",
    )
    with patch(
        "app.api.vision.identify_ingredient", return_value=fake_result
    ) as mock_call:
        response = client.post(
            "/api/vision/identify-ingredient",
            json={
                "image_base64": base64.b64encode(_png_bytes()).decode("ascii"),
                "mime_type": "image/png",
            },
        )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["name"] == "habanero pepper"
    assert payload["confidence"] == "high"
    assert "habanero" in payload["recipe_match_terms"]
    assert mock_call.call_count == 1


def test_identify_ingredient_rejects_bad_base64(client) -> None:
    response = client.post(
        "/api/vision/identify-ingredient",
        json={"image_base64": "!!!not-valid-base64!!!", "mime_type": "image/png"},
    )
    assert response.status_code == 400
    assert "Invalid base64" in response.json()["detail"]


def test_identify_ingredient_surfaces_provider_error_as_502(client) -> None:
    with patch(
        "app.api.vision.identify_ingredient",
        side_effect=RuntimeError("No vision-capable AI provider is configured."),
    ):
        response = client.post(
            "/api/vision/identify-ingredient",
            json={
                "image_base64": base64.b64encode(_png_bytes()).decode("ascii"),
                "mime_type": "image/png",
            },
        )
    assert response.status_code == 502
    assert "No vision-capable" in response.json()["detail"]


def test_identify_ingredient_surfaces_validation_error_as_400(client) -> None:
    with patch(
        "app.api.vision.identify_ingredient",
        side_effect=ValueError("Image is too large"),
    ):
        response = client.post(
            "/api/vision/identify-ingredient",
            json={
                "image_base64": base64.b64encode(_png_bytes()).decode("ascii"),
                "mime_type": "image/png",
            },
        )
    assert response.status_code == 400
    assert "Image is too large" in response.json()["detail"]


def _seed_recipe(client) -> str:
    response = client.post(
        "/api/recipes",
        json={
            "name": "Roast chicken",
            "cuisine": "American",
            "meal_type": "dinner",
            "servings": 4.0,
            "ingredients": [],
            "steps": [
                {"step_number": 0, "instruction": "Preheat oven to 425°F."},
                {"step_number": 1, "instruction": "Roast chicken for 1 hour."},
            ],
        },
    )
    assert response.status_code == 200, response.text
    return response.json()["recipe_id"]


def test_cook_check_route_returns_verdict(client) -> None:
    from app.services.vision_ai import CookCheckTip

    recipe_id = _seed_recipe(client)
    fake = CookCheckTip(verdict="on_track", tip="Looks great.", suggested_minutes_remaining=0)
    with patch("app.services.vision_ai.check_cooking_progress", return_value=fake):
        response = client.post(
            f"/api/recipes/{recipe_id}/cook-check",
            json={
                "image_base64": base64.b64encode(_png_bytes()).decode("ascii"),
                "mime_type": "image/png",
                "step_number": 1,
            },
        )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["verdict"] == "on_track"
    assert payload["tip"] == "Looks great."


def test_cook_check_404_when_recipe_missing(client) -> None:
    response = client.post(
        "/api/recipes/does-not-exist/cook-check",
        json={
            "image_base64": base64.b64encode(_png_bytes()).decode("ascii"),
            "mime_type": "image/png",
            "step_number": 0,
        },
    )
    assert response.status_code == 404
