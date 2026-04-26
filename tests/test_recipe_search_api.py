"""Tests for the AI recipe web search route (M12 Phase 4).

Mocks the OpenAI Responses API HTTP call with a fixture payload and
asserts the route returns a parsed `RecipePayload`. Real-world
behavior depends on OPENAI_API_KEY being set on the host; we don't
exercise that here.
"""
from __future__ import annotations

import json
from unittest.mock import patch


_FAKE_AI_RECIPE = {
    "name": "Yeasted Whole Wheat Waffles",
    "source_url": "https://www.seriouseats.com/yeast-raised-whole-wheat-waffles",
    "source_label": "Serious Eats",
    "cuisine": "American",
    "meal_type": "breakfast",
    "servings": 4,
    "prep_minutes": 10,
    "cook_minutes": 15,
    "ingredients": [
        {"ingredient_name": "whole wheat flour", "quantity": 1.5, "unit": "cup"},
        {"ingredient_name": "active dry yeast", "quantity": 1.0, "unit": "tsp"},
    ],
    "steps": [
        {"step_number": 0, "instruction": "Combine dry ingredients."},
        {"step_number": 1, "instruction": "Whisk in milk + butter."},
    ],
    "notes": "Yeast-raised — crisp edges, deep flavor.",
}


class _FakeResponse:
    def __init__(self, payload: dict):
        self._payload = payload
        self.status_code = 200

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


class _FakeClient:
    def __init__(self, *args, **kwargs):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def post(self, url, *, headers, json):
        # Return a Responses API-shaped payload that wraps the AI recipe
        # JSON inside an `output_text` block.
        return _FakeResponse(
            {
                "output": [
                    {"type": "web_search_call"},
                    {
                        "type": "message",
                        "content": [
                            {
                                "type": "output_text",
                                "text": __import__("json").dumps(_FAKE_AI_RECIPE),
                            }
                        ],
                    },
                ]
            }
        )


def _settings_patches(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.recipe_search_ai.direct_provider_availability",
        lambda name, **k: (name == "openai", "server_key"),
    )
    monkeypatch.setattr(
        "app.services.recipe_search_ai.resolve_direct_api_key",
        lambda *a, **k: "fake-openai-key",
    )
    monkeypatch.setattr(
        "app.services.recipe_search_ai.resolve_direct_model",
        lambda *a, **k: "gpt-4o",
    )
    monkeypatch.setattr(
        "app.services.recipe_search_ai.httpx.Client", _FakeClient
    )


def test_web_search_returns_recipe_payload(client, monkeypatch) -> None:
    _settings_patches(monkeypatch)
    response = client.post(
        "/api/recipes/ai/web-search",
        json={"query": "best whole wheat waffle recipe"},
    )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["name"] == "Yeasted Whole Wheat Waffles"
    assert payload["source_url"].startswith("https://www.seriouseats.com")
    assert payload["source"] == "ai_web_search"
    assert len(payload["ingredients"]) == 2
    assert len(payload["steps"]) == 2
    assert payload["steps"][0]["sort_order"] == 0


def test_web_search_502_when_no_openai(client, monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.recipe_search_ai.direct_provider_availability",
        lambda name, **k: (False, "unconfigured"),
    )
    response = client.post(
        "/api/recipes/ai/web-search",
        json={"query": "anything"},
    )
    assert response.status_code == 502
    assert "OpenAI" in response.json()["detail"]


def test_web_search_400_on_short_query(client) -> None:
    response = client.post(
        "/api/recipes/ai/web-search",
        json={"query": "x"},
    )
    assert response.status_code == 422


def test_web_search_502_on_bad_json(client, monkeypatch) -> None:
    _settings_patches(monkeypatch)

    class _BadJSONClient(_FakeClient):
        def post(self, url, *, headers, json):
            return _FakeResponse(
                {
                    "output": [
                        {
                            "type": "message",
                            "content": [
                                {"type": "output_text", "text": "not actual json"}
                            ],
                        }
                    ]
                }
            )

    monkeypatch.setattr(
        "app.services.recipe_search_ai.httpx.Client", _BadJSONClient
    )
    response = client.post(
        "/api/recipes/ai/web-search",
        json={"query": "best whole wheat waffle recipe"},
    )
    assert response.status_code == 502
