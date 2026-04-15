"""Kroger API client — OAuth2 auth, store search, and product pricing."""
from __future__ import annotations

import base64
import logging
import time

import httpx

from app.config import Settings

logger = logging.getLogger(__name__)

BASE_URL = "https://api.kroger.com"
TOKEN_URL = f"{BASE_URL}/v1/connect/oauth2/token"
PRODUCTS_URL = f"{BASE_URL}/v1/products"
LOCATIONS_URL = f"{BASE_URL}/v1/locations"

# Cache the access token in-process (expires after ~30 min typically).
_token_cache: dict[str, object] = {"token": None, "expires_at": 0.0}


def _get_access_token(settings: Settings) -> str:
    """Obtain an OAuth2 client-credentials token, using a simple in-process cache."""
    now = time.time()
    if _token_cache["token"] and now < float(_token_cache["expires_at"]):
        return str(_token_cache["token"])

    client_id = settings.kroger_client_id
    client_secret = settings.kroger_client_secret
    if not client_id or not client_secret:
        raise RuntimeError(
            "Kroger API not configured. Set SIMMERSMITH_KROGER_CLIENT_ID and "
            "SIMMERSMITH_KROGER_CLIENT_SECRET."
        )

    credentials = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    with httpx.Client(timeout=15) as client:
        resp = client.post(
            TOKEN_URL,
            headers={
                "Authorization": f"Basic {credentials}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            data={"grant_type": "client_credentials", "scope": "product.compact"},
        )
    resp.raise_for_status()
    data = resp.json()
    access_token = data["access_token"]
    expires_in = data.get("expires_in", 1800)

    _token_cache["token"] = access_token
    _token_cache["expires_at"] = now + expires_in - 60  # refresh 60s early

    return str(access_token)


def _auth_headers(settings: Settings) -> dict[str, str]:
    token = _get_access_token(settings)
    return {"Authorization": f"Bearer {token}", "Accept": "application/json"}


def search_locations(
    settings: Settings, *, zip_code: str, radius_miles: int = 10, limit: int = 10,
) -> list[dict]:
    """Search Kroger-family stores near a zip code.

    Returns a list of dicts with keys: location_id, name, chain, address, city,
    state, zip_code, phone.
    """
    headers = _auth_headers(settings)
    params: dict[str, str | int] = {
        "filter.zipCode.near": zip_code,
        "filter.radiusInMiles": radius_miles,
        "filter.limit": limit,
    }
    with httpx.Client(timeout=15) as client:
        resp = client.get(LOCATIONS_URL, headers=headers, params=params)
    resp.raise_for_status()

    results: list[dict] = []
    for loc in resp.json().get("data", []):
        address = loc.get("address", {})
        results.append({
            "location_id": loc.get("locationId", ""),
            "name": loc.get("name", ""),
            "chain": loc.get("chain", ""),
            "address": address.get("addressLine1", ""),
            "city": address.get("city", ""),
            "state": address.get("state", ""),
            "zip_code": address.get("zipCode", ""),
            "phone": loc.get("phone", ""),
        })
    return results


def search_product_price(
    settings: Settings, *, term: str, location_id: str, limit: int = 5,
) -> list[dict]:
    """Search Kroger products by ingredient term at a specific store.

    Returns a list of dicts with keys: product_id, upc, brand, description,
    package_size, regular_price, promo_price, product_url, in_stock.
    """
    headers = _auth_headers(settings)
    params: dict[str, str | int] = {
        "filter.term": term,
        "filter.locationId": location_id,
        "filter.limit": limit,
    }
    with httpx.Client(timeout=15) as client:
        resp = client.get(PRODUCTS_URL, headers=headers, params=params)
    resp.raise_for_status()

    results: list[dict] = []
    for product in resp.json().get("data", []):
        # Price structure: items[0].price.regular, items[0].price.promo
        items = product.get("items", [])
        price_info = items[0].get("price", {}) if items else {}
        size_info = items[0].get("size", "") if items else ""
        fulfillment = items[0].get("fulfillment", {}) if items else {}

        regular_price = price_info.get("regular")
        promo_price = price_info.get("promo")

        results.append({
            "product_id": product.get("productId", ""),
            "upc": product.get("upc", ""),
            "brand": product.get("brand", ""),
            "description": product.get("description", ""),
            "package_size": str(size_info) if size_info else "",
            "regular_price": float(regular_price) if regular_price else None,
            "promo_price": float(promo_price) if promo_price else None,
            "product_url": f"https://www.kroger.com/p/{product.get('productId', '')}",
            "in_stock": fulfillment.get("inStore", False),
        })
    return results


def pick_best_match(candidates: list[dict], query_term: str) -> dict | None:
    """Pick the best product match from search results.

    Prefers: in-stock > has price > description relevance.
    Returns None if no candidates have pricing.
    """
    if not candidates:
        return None

    scored: list[tuple[float, dict]] = []
    query_lower = query_term.lower()
    for c in candidates:
        score = 0.0
        if c.get("in_stock"):
            score += 10
        if c.get("regular_price") is not None:
            score += 5
        if c.get("promo_price") is not None:
            score += 2
        desc = (c.get("description") or "").lower()
        if query_lower in desc:
            score += 3
        scored.append((score, c))

    scored.sort(key=lambda x: x[0], reverse=True)
    best = scored[0][1]
    return best if best.get("regular_price") is not None else None


def clear_token_cache() -> None:
    """Clear the cached access token (useful for testing)."""
    _token_cache["token"] = None
    _token_cache["expires_at"] = 0.0
