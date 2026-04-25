"""Integration tests for the UPC reverse-lookup route (M11 Phase 4)."""
from __future__ import annotations

from unittest.mock import patch

from app.config import get_settings


def test_lookup_upc_503_when_kroger_unconfigured(client) -> None:
    response = client.post(
        "/api/products/lookup-upc",
        json={"upc": "012345678901", "location_id": "70300100"},
    )
    assert response.status_code == 503
    assert "Kroger API not configured" in response.json()["detail"]


def test_lookup_upc_returns_match(client, monkeypatch) -> None:
    settings = get_settings()
    monkeypatch.setattr(settings, "kroger_client_id", "fake-id")
    monkeypatch.setattr(settings, "kroger_client_secret", "fake-secret")

    fake_match = {
        "product_id": "0001111041700",
        "upc": "0001111041700",
        "brand": "Kroger",
        "description": "Kroger 2% Reduced Fat Milk, 1 Gallon",
        "package_size": "1 gal",
        "regular_price": 3.79,
        "promo_price": None,
        "product_url": "https://www.kroger.com/p/0001111041700",
        "in_stock": True,
    }
    with patch(
        "app.services.kroger.search_product_by_upc", return_value=fake_match
    ):
        response = client.post(
            "/api/products/lookup-upc",
            json={"upc": "0001111041700", "location_id": "70300100"},
        )

    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["upc"] == "0001111041700"
    assert payload["brand"] == "Kroger"
    assert payload["regular_price"] == 3.79
    assert payload["in_stock"] is True


def test_lookup_upc_404_when_no_match(client, monkeypatch) -> None:
    settings = get_settings()
    monkeypatch.setattr(settings, "kroger_client_id", "fake-id")
    monkeypatch.setattr(settings, "kroger_client_secret", "fake-secret")
    with patch("app.services.kroger.search_product_by_upc", return_value=None):
        response = client.post(
            "/api/products/lookup-upc",
            json={"upc": "999999999999", "location_id": "70300100"},
        )
    assert response.status_code == 404
    assert "999999999999" in response.json()["detail"]


def test_lookup_upc_validates_short_upc(client) -> None:
    response = client.post(
        "/api/products/lookup-upc",
        json={"upc": "12", "location_id": "70300100"},
    )
    assert response.status_code == 422
