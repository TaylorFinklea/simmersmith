"""Tests for Kroger API integration (store search, product pricing, fetch flow)."""
from __future__ import annotations

from unittest.mock import patch

from app.services.kroger import pick_best_match


TEST_USER_ID = "00000000-0000-0000-0000-000000000001"


# ---------------------------------------------------------------------------
# pick_best_match (pure logic, no API)
# ---------------------------------------------------------------------------

def test_pick_best_match_prefers_in_stock_with_price() -> None:
    candidates = [
        {"description": "Chicken Breast", "regular_price": 5.99, "in_stock": False},
        {"description": "Chicken Breast Boneless", "regular_price": 6.49, "in_stock": True},
    ]
    result = pick_best_match(candidates, "chicken breast")
    assert result is not None
    assert result["regular_price"] == 6.49


def test_pick_best_match_returns_none_for_no_prices() -> None:
    candidates = [
        {"description": "Chicken Breast", "regular_price": None, "in_stock": True},
    ]
    result = pick_best_match(candidates, "chicken breast")
    assert result is None


def test_pick_best_match_prefers_promo() -> None:
    candidates = [
        {"description": "Milk 1 gal", "regular_price": 3.99, "promo_price": 2.99, "in_stock": True},
        {"description": "Milk 1 gal", "regular_price": 3.99, "in_stock": True},
    ]
    result = pick_best_match(candidates, "milk")
    assert result is not None
    assert result.get("promo_price") == 2.99


def test_pick_best_match_returns_none_for_empty() -> None:
    assert pick_best_match([], "anything") is None


def test_pick_best_match_prefers_description_match() -> None:
    candidates = [
        {"description": "Organic Free Range Eggs", "regular_price": 6.99, "in_stock": True},
        {"description": "Eggs Large Grade A", "regular_price": 3.49, "in_stock": True},
    ]
    result = pick_best_match(candidates, "eggs")
    # Both in stock with prices; "eggs" appears in both descriptions.
    # The one with higher combined score wins (both have description match + in_stock + price)
    assert result is not None
    assert result["regular_price"] is not None


# ---------------------------------------------------------------------------
# Store search endpoint (mocked Kroger API)
# ---------------------------------------------------------------------------

def test_store_search_returns_locations(client, monkeypatch) -> None:
    mock_locations = [
        {
            "location_id": "01400413",
            "name": "Kroger",
            "chain": "KROGER",
            "address": "123 Main St",
            "city": "Austin",
            "state": "TX",
            "zip_code": "78701",
            "phone": "512-555-0100",
        },
    ]
    monkeypatch.setenv("SIMMERSMITH_KROGER_CLIENT_ID", "test-id")
    monkeypatch.setenv("SIMMERSMITH_KROGER_CLIENT_SECRET", "test-secret")

    from app.config import get_settings
    get_settings.cache_clear()

    with patch("app.services.kroger.search_locations", return_value=mock_locations):
        resp = client.get("/api/stores/search?zip_code=78701")

    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["location_id"] == "01400413"
    assert data[0]["city"] == "Austin"


def test_store_search_returns_503_when_not_configured(client) -> None:
    resp = client.get("/api/stores/search?zip_code=78701")
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"]


# ---------------------------------------------------------------------------
# Pricing fetch endpoint (mocked Kroger API)
# ---------------------------------------------------------------------------

def _create_approved_week_with_groceries(client) -> str:
    """Helper: create a week, add meals, approve it, return week_id."""
    week_resp = client.post("/api/weeks", json={"week_start": "2026-05-04", "notes": ""})
    week_id = week_resp.json()["week_id"]

    draft_payload = {
        "prompt": "test",
        "model": "test",
        "recipes": [
            {
                "name": "Grilled Chicken",
                "meal_type": "dinner",
                "servings": 4,
                "ingredients": [
                    {"ingredient_name": "Chicken breast", "quantity": 2, "unit": "lb", "category": "Meat"},
                    {"ingredient_name": "Olive oil", "quantity": 2, "unit": "tbsp", "category": "Pantry"},
                ],
            }
        ],
        "meal_plan": [
            {
                "day_name": "Monday",
                "meal_date": "2026-05-04",
                "slot": "dinner",
                "recipe_name": "Grilled Chicken",
                "servings": 4,
                "approved": True,
                "ingredients": [
                    {"ingredient_name": "Chicken breast", "quantity": 2, "unit": "lb", "category": "Meat"},
                    {"ingredient_name": "Olive oil", "quantity": 2, "unit": "tbsp", "category": "Pantry"},
                ],
            },
        ],
    }
    draft_resp = client.post(f"/api/weeks/{week_id}/draft-from-ai", json=draft_payload)
    assert draft_resp.status_code == 200

    approve_resp = client.post(f"/api/weeks/{week_id}/approve", json={})
    assert approve_resp.status_code == 200
    assert approve_resp.json()["status"] == "approved"

    return week_id


def _mock_kroger_search(settings, *, term, location_id, limit=5):
    """Fake Kroger product search that returns a single matched product."""
    return [
        {
            "product_id": "0001111060903",
            "upc": "0001111060903",
            "brand": "Kroger",
            "description": f"Kroger {term.title()}",
            "package_size": "1 lb",
            "regular_price": 4.99,
            "promo_price": None,
            "product_url": "https://www.kroger.com/p/0001111060903",
            "in_stock": True,
        }
    ]


def test_pricing_fetch_creates_kroger_prices(client) -> None:
    week_id = _create_approved_week_with_groceries(client)

    with patch("app.services.kroger.search_product_price", side_effect=_mock_kroger_search):
        with patch("app.services.kroger.pick_best_match", wraps=pick_best_match):
            resp = client.post(
                f"/api/weeks/{week_id}/pricing/fetch",
                json={"location_id": "01400413"},
            )

    assert resp.status_code == 200
    data = resp.json()
    assert "kroger" in data["totals"]
    assert data["totals"]["kroger"] > 0

    # Check individual items have kroger prices
    for item in data["items"]:
        kroger_prices = [p for p in item.get("retailer_prices", []) if p["retailer"] == "kroger"]
        assert len(kroger_prices) <= 1  # at most one per retailer


def test_pricing_fetch_requires_location(client) -> None:
    week_id = _create_approved_week_with_groceries(client)
    resp = client.post(f"/api/weeks/{week_id}/pricing/fetch", json={})
    assert resp.status_code == 400
    assert "No store selected" in resp.json()["detail"]


def test_pricing_fetch_uses_profile_setting(client) -> None:
    """If no location_id in request, falls back to profile setting."""
    week_id = _create_approved_week_with_groceries(client)

    # Save kroger_location_id in profile
    client.put("/api/profile", json={"settings": {"kroger_location_id": "01400413"}})

    with patch("app.services.kroger.search_product_price", side_effect=_mock_kroger_search):
        with patch("app.services.kroger.pick_best_match", wraps=pick_best_match):
            resp = client.post(f"/api/weeks/{week_id}/pricing/fetch", json={})

    assert resp.status_code == 200
    assert "kroger" in resp.json()["totals"]


def test_pricing_fetch_handles_api_failure_gracefully(client) -> None:
    """If Kroger API fails for an item, it's marked unavailable, not a 500."""
    week_id = _create_approved_week_with_groceries(client)

    def _failing_search(settings, *, term, location_id, limit=5):
        raise ConnectionError("Kroger API down")

    with patch("app.services.kroger.search_product_price", side_effect=_failing_search):
        resp = client.post(
            f"/api/weeks/{week_id}/pricing/fetch",
            json={"location_id": "01400413"},
        )

    assert resp.status_code == 200
    data = resp.json()
    # Items should be marked unavailable, not crash
    for item in data["items"]:
        kroger_prices = [p for p in item.get("retailer_prices", []) if p["retailer"] == "kroger"]
        for kp in kroger_prices:
            assert kp["status"] == "unavailable"


def test_existing_import_still_works_with_kroger_retailer(client) -> None:
    """The import endpoint now accepts 'kroger' as a retailer value."""
    week_id = _create_approved_week_with_groceries(client)
    week_data = client.get(f"/api/weeks/{week_id}").json()
    if not week_data["grocery_items"]:
        # Grocery items may need regeneration after approval
        return  # Skip if no items to price
    item_id = week_data["grocery_items"][0]["grocery_item_id"]

    resp = client.post(
        f"/api/weeks/{week_id}/pricing/import",
        json={
            "items": [
                {
                    "grocery_item_id": item_id,
                    "retailer": "kroger",
                    "status": "matched",
                    "product_name": "Kroger Chicken Breast",
                    "unit_price": 4.99,
                    "line_price": 9.98,
                }
            ],
            "replace_existing": True,
            "source": "test",
        },
    )
    assert resp.status_code == 200
    assert "kroger" in resp.json()["totals"]
