"""Integration tests for the recipe-pairings route (M12 Phase 1)."""
from __future__ import annotations

from unittest.mock import patch

from app.services.pairing_ai import PairingOption


def _seed_recipe(client) -> str:
    response = client.post(
        "/api/recipes",
        json={
            "name": "Roast chicken",
            "cuisine": "American",
            "meal_type": "dinner",
            "servings": 4.0,
            "ingredients": [],
            "steps": [],
        },
    )
    assert response.status_code == 200, response.text
    return response.json()["recipe_id"]


def test_pairings_route_returns_three(client) -> None:
    recipe_id = _seed_recipe(client)
    fake = [
        PairingOption(name="Caesar salad", role="side", reason="Crisp + bright."),
        PairingOption(name="Sparkling lemonade", role="drink", reason="Cuts the fat."),
        PairingOption(name="Apple crumble", role="dessert", reason="Warming finish."),
    ]
    with patch("app.services.pairing_ai.suggest_pairings", return_value=fake):
        response = client.post(f"/api/recipes/{recipe_id}/pairings")

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["recipe_id"] == recipe_id
    assert len(payload["suggestions"]) == 3
    roles = {s["role"] for s in payload["suggestions"]}
    assert roles == {"side", "drink", "dessert"}


def test_pairings_route_404_when_recipe_missing(client) -> None:
    response = client.post("/api/recipes/does-not-exist/pairings")
    assert response.status_code == 404


def test_pairings_route_502_on_provider_error(client) -> None:
    recipe_id = _seed_recipe(client)
    with patch(
        "app.services.pairing_ai.suggest_pairings",
        side_effect=RuntimeError("No direct AI provider is configured."),
    ):
        response = client.post(f"/api/recipes/{recipe_id}/pairings")
    assert response.status_code == 502
    assert "AI provider" in response.json()["detail"]
