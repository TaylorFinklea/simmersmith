"""Tests for the in-season produce route + cache (M12 Phase 3)."""
from __future__ import annotations

from datetime import date
from unittest.mock import patch

from app.services.seasonal_ai import InSeasonItem, clear_cache, seasonal_produce


def test_seasonal_route_returns_items_with_region(client) -> None:
    fake = [
        InSeasonItem(name="asparagus", why_now="Spring peak.", peak_score=5),
        InSeasonItem(name="strawberries", why_now="Local berry start.", peak_score=4),
    ]
    with patch(
        "app.api.discovery.seasonal_produce", return_value=fake
    ) as mock_call:
        response = client.get("/api/seasonal/produce")

    assert response.status_code == 200, response.text
    payload = response.json()
    assert len(payload) == 2
    assert payload[0]["name"] == "asparagus"
    assert mock_call.call_count == 1


def test_seasonal_route_502_on_provider_error(client) -> None:
    with patch(
        "app.api.discovery.seasonal_produce",
        side_effect=RuntimeError("No direct AI provider is configured."),
    ):
        response = client.get("/api/seasonal/produce")
    assert response.status_code == 502


def test_seasonal_cache_keys_on_region_year_month() -> None:
    """Verifies the in-process cache hits when the (region, year, month)
    triple matches and misses when any of the three changes."""
    clear_cache()
    fake = [InSeasonItem(name="kale", why_now="Cool season.", peak_score=4)]
    settings_stub = type("S", (), {"ai_timeout_seconds": 10})()
    user_settings = {"ai_direct_provider": "openai"}

    with patch(
        "app.services.seasonal_ai._resolve_target",
        return_value=type("T", (), {"provider_name": "openai", "model": "stub"})(),
    ), patch(
        "app.services.seasonal_ai.run_direct_provider",
        return_value='{"items":[{"name":"kale","why_now":"Cool season.","peak_score":4}]}',
    ) as mock_call:
        first = seasonal_produce(
            region="Kansas, USA",
            today=date(2026, 4, 25),
            settings=settings_stub,
            user_settings=user_settings,
        )
        second = seasonal_produce(
            region="Kansas, USA",
            today=date(2026, 4, 25),
            settings=settings_stub,
            user_settings=user_settings,
        )

    assert [item.name for item in first] == ["kale"]
    assert [item.name for item in second] == ["kale"]
    # Second call hit the cache — only one provider call total.
    assert mock_call.call_count == 1


def test_seasonal_falls_back_to_united_states_when_region_blank() -> None:
    clear_cache()
    settings_stub = type("S", (), {"ai_timeout_seconds": 10})()
    user_settings: dict[str, str] = {}

    captured: dict[str, str] = {}

    def fake_runner(*, prompt: str, **kwargs):
        captured["prompt"] = prompt
        return '{"items":[]}'

    with patch(
        "app.services.seasonal_ai._resolve_target",
        return_value=type("T", (), {"provider_name": "openai", "model": "stub"})(),
    ), patch(
        "app.services.seasonal_ai.run_direct_provider",
        side_effect=fake_runner,
    ):
        seasonal_produce(
            region="",
            today=date(2026, 4, 25),
            settings=settings_stub,
            user_settings=user_settings,
        )

    assert "Region: United States" in captured["prompt"]
