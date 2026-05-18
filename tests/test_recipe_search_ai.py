"""Tests for the dual-provider recipe web search service.

Mocks `httpx.Client` and the provider-resolution helpers so the tests
don't need real API keys. Covers:

- Provider router: user setting > global > openai default.
- Missing-API-key raises a helpful provider-specific error.
- OpenAI request shape + Responses-payload parsing.
- Anthropic request shape + Messages-payload parsing (incl. skipping
  intermediate `server_tool_use` / `web_search_tool_result` blocks).
- Empty query raises ValueError.
- Garbage model output raises RuntimeError with a useful message.
"""
from __future__ import annotations

import json

import pytest

from app.config import Settings
from app.services.recipe_search_ai import (
    _resolve_provider,
    search_recipe,
)


def _settings(
    *,
    ai_recipe_search_provider: str = "openai",
    ai_openai_api_key: str = "fake-openai-key",
    ai_anthropic_api_key: str = "fake-anthropic-key",
) -> Settings:
    return Settings(
        ai_openai_api_key=ai_openai_api_key,
        ai_anthropic_api_key=ai_anthropic_api_key,
        ai_mcp_enabled=False,
        ai_openai_model="gpt-5.5",
        ai_anthropic_model="claude-sonnet-4-6",
        ai_recipe_search_provider=ai_recipe_search_provider,
    )


_RECIPE_JSON = json.dumps(
    {
        "name": "Yeast-Raised Whole-Wheat Waffles",
        "source_url": "https://www.seriouseats.com/yeast-waffles-recipe",
        "source_label": "Serious Eats",
        "cuisine": "American",
        "meal_type": "breakfast",
        "servings": 4,
        "prep_minutes": 15,
        "cook_minutes": 10,
        "ingredients": [
            {"ingredient_name": "whole wheat flour", "quantity": 1.5, "unit": "cup", "prep": ""},
            {"ingredient_name": "active dry yeast", "quantity": 0.25, "unit": "tsp", "prep": ""},
        ],
        "steps": [
            {"step_number": 1, "instruction": "Whisk flour and yeast."},
            {"step_number": 2, "instruction": "Cook on iron 4 minutes per side."},
        ],
        "notes": "Yeast-raised gives crisp edges and chewy interior.",
    }
)


class _FakeResponse:
    def __init__(self, payload: dict, status: int = 200) -> None:
        self._payload = payload
        self.status_code = status

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"http {self.status_code}")

    def json(self) -> dict:
        return self._payload


class _FakeClient:
    """Stand-in for httpx.Client. Captures the most recent request body
    + URL + headers so tests can assert on them, returns a canned
    payload from class-level `next_payload`."""

    next_payload: dict | None = None
    last_url: str | None = None
    last_headers: dict | None = None
    last_body: dict | None = None

    def __init__(self, *args, **kwargs) -> None:
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args) -> None:
        return None

    def post(self, url: str, *, headers: dict, json: dict) -> _FakeResponse:
        type(self).last_url = url
        type(self).last_headers = headers
        type(self).last_body = json
        return _FakeResponse(type(self).next_payload or {})


def _patch(monkeypatch, *, provider: str, payload: dict) -> None:
    _FakeClient.next_payload = payload
    _FakeClient.last_url = None
    _FakeClient.last_headers = None
    _FakeClient.last_body = None
    monkeypatch.setattr("app.services.recipe_search_ai.httpx.Client", _FakeClient)
    monkeypatch.setattr(
        "app.services.recipe_search_ai.resolve_direct_api_key",
        lambda name, **k: f"fake-{name}-key",
    )
    monkeypatch.setattr(
        "app.services.recipe_search_ai.direct_provider_availability",
        lambda name, **k: (name == provider, "server_key"),
    )
    monkeypatch.setattr(
        "app.services.recipe_search_ai.resolve_direct_model",
        lambda name, **k: "gpt-5.5" if name == "openai" else "claude-sonnet-4-6",
    )


# ---------------------------------------------------------------------
# Provider router
# ---------------------------------------------------------------------


class TestResolveProvider:
    def test_user_setting_wins_over_global(self) -> None:
        settings = _settings(ai_recipe_search_provider="openai")
        assert _resolve_provider(settings, {"recipe_search_provider": "anthropic"}) == "anthropic"

    def test_global_setting_used_when_no_user_choice(self) -> None:
        settings = _settings(ai_recipe_search_provider="anthropic")
        assert _resolve_provider(settings, {}) == "anthropic"

    def test_defaults_to_openai_when_nothing_configured(self) -> None:
        settings = _settings(ai_recipe_search_provider="")
        assert _resolve_provider(settings, {}) == "openai"

    def test_invalid_user_choice_falls_through_to_global(self) -> None:
        settings = _settings(ai_recipe_search_provider="anthropic")
        assert _resolve_provider(settings, {"recipe_search_provider": "bogus"}) == "anthropic"


# ---------------------------------------------------------------------
# OpenAI path
# ---------------------------------------------------------------------


class TestOpenAIPath:
    def test_search_succeeds_and_builds_correct_request(self, monkeypatch) -> None:
        _patch(
            monkeypatch,
            provider="openai",
            payload={
                "output": [
                    {"type": "web_search_call", "id": "ws_1"},
                    {
                        "type": "message",
                        "content": [{"type": "output_text", "text": _RECIPE_JSON}],
                    },
                ]
            },
        )
        payload = search_recipe(
            query="waffles",
            settings=_settings(ai_recipe_search_provider="openai"),
            user_settings={},
        )
        assert payload.name == "Yeast-Raised Whole-Wheat Waffles"
        assert payload.source == "ai_web_search"
        assert payload.source_url.startswith("https://")
        assert len(payload.ingredients) == 2
        assert len(payload.steps) == 2
        # Verify wire format: Responses URL, web_search tool requested.
        assert _FakeClient.last_url == "https://api.openai.com/v1/responses"
        assert _FakeClient.last_body is not None
        assert _FakeClient.last_body["tools"] == [{"type": "web_search"}]
        assert _FakeClient.last_body["model"] == "gpt-5.5"

    def test_search_handles_top_level_output_text(self, monkeypatch) -> None:
        """Some Responses payloads collapse the message tree into a flat
        `output_text` field; we should still parse it."""
        _patch(
            monkeypatch,
            provider="openai",
            payload={"output_text": _RECIPE_JSON, "output": []},
        )
        payload = search_recipe(
            query="anything",
            settings=_settings(),
            user_settings={},
        )
        assert payload.name


# ---------------------------------------------------------------------
# Anthropic path
# ---------------------------------------------------------------------


class TestAnthropicPath:
    def test_search_succeeds_and_builds_correct_request(self, monkeypatch) -> None:
        _patch(
            monkeypatch,
            provider="anthropic",
            payload={
                "id": "msg_1",
                "type": "message",
                "role": "assistant",
                "content": [
                    {"type": "server_tool_use", "id": "tu_1", "name": "web_search",
                     "input": {"query": "yeast waffles"}},
                    {"type": "web_search_tool_result", "tool_use_id": "tu_1", "content": []},
                    {"type": "text", "text": _RECIPE_JSON},
                ],
            },
        )
        payload = search_recipe(
            query="waffles",
            settings=_settings(ai_recipe_search_provider="anthropic"),
            user_settings={},
        )
        assert payload.name == "Yeast-Raised Whole-Wheat Waffles"
        assert payload.source_label == "Serious Eats"
        # Verify wire format: Anthropic Messages URL, web_search_20250305 tool.
        assert _FakeClient.last_url == "https://api.anthropic.com/v1/messages"
        assert _FakeClient.last_body is not None
        assert _FakeClient.last_body["model"] == "claude-sonnet-4-6"
        assert _FakeClient.last_body["tools"][0]["type"] == "web_search_20250305"
        # Anthropic API version header is required.
        assert _FakeClient.last_headers is not None
        assert _FakeClient.last_headers["anthropic-version"] == "2023-06-01"
        assert _FakeClient.last_headers["x-api-key"] == "fake-anthropic-key"

    def test_search_skips_tool_blocks_and_concatenates_text(self, monkeypatch) -> None:
        """Anthropic streams tool_use + tool_result blocks before the
        final text. The parser must skip the tool blocks cleanly."""
        _patch(
            monkeypatch,
            provider="anthropic",
            payload={
                "content": [
                    {"type": "server_tool_use", "id": "1", "name": "web_search", "input": {}},
                    {"type": "web_search_tool_result", "tool_use_id": "1", "content": []},
                    {"type": "text", "text": "Some preamble I'll ignore...\n"},
                    {"type": "server_tool_use", "id": "2", "name": "web_search", "input": {}},
                    {"type": "web_search_tool_result", "tool_use_id": "2", "content": []},
                    {"type": "text", "text": _RECIPE_JSON},
                ],
            },
        )
        payload = search_recipe(
            query="waffles",
            settings=_settings(ai_recipe_search_provider="anthropic"),
            user_settings={},
        )
        assert payload.name == "Yeast-Raised Whole-Wheat Waffles"


# ---------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------


class TestErrorPaths:
    def test_empty_query_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="empty"):
            search_recipe(
                query="   ",
                settings=_settings(),
                user_settings={},
            )

    def test_missing_openai_key_names_openai(self, monkeypatch) -> None:
        monkeypatch.setattr(
            "app.services.recipe_search_ai.direct_provider_availability",
            lambda name, **k: (False, ""),
        )
        with pytest.raises(RuntimeError, match="OPENAI_API_KEY"):
            search_recipe(
                query="anything",
                settings=_settings(ai_recipe_search_provider="openai"),
                user_settings={},
            )

    def test_missing_anthropic_key_names_anthropic(self, monkeypatch) -> None:
        monkeypatch.setattr(
            "app.services.recipe_search_ai.direct_provider_availability",
            lambda name, **k: (False, ""),
        )
        with pytest.raises(RuntimeError, match="ANTHROPIC_API_KEY"):
            search_recipe(
                query="anything",
                settings=_settings(ai_recipe_search_provider="anthropic"),
                user_settings={},
            )

    def test_invalid_json_raises_runtime_error(self, monkeypatch) -> None:
        _patch(
            monkeypatch,
            provider="openai",
            payload={"output_text": "not even close to JSON"},
        )
        with pytest.raises(RuntimeError, match="JSON"):
            search_recipe(
                query="waffles",
                settings=_settings(),
                user_settings={},
            )

    def test_schema_mismatch_raises_runtime_error(self, monkeypatch) -> None:
        _patch(
            monkeypatch,
            provider="openai",
            payload={"output_text": json.dumps({"wrong": "shape"})},
        )
        with pytest.raises(RuntimeError, match="shape"):
            search_recipe(
                query="waffles",
                settings=_settings(),
                user_settings={},
            )
