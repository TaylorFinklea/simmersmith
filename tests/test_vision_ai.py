"""Tests for app/services/vision_ai.py.

Mocks httpx.Client.post and the provider-resolution helpers so the tests
don't need real API keys. Asserts the strict-JSON path parses correctly
and that image validation rejects bad inputs.
"""
from __future__ import annotations

import json

import pytest

from app.config import Settings
from app.services.vision_ai import (
    MAX_IMAGE_BYTES,
    CookCheckTip,
    IngredientIdentification,
    check_cooking_progress,
    identify_ingredient,
)


def _settings() -> Settings:
    return Settings(
        ai_openai_api_key="fake-key",
        ai_anthropic_api_key="",
        ai_mcp_enabled=False,
        ai_openai_model="gpt-5.4-mini",
    )


class _FakeResponse:
    def __init__(self, payload: dict):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


class _FakeClient:
    """Stand-in for httpx.Client. Captures the body of the last post() call
    and returns a canned response. The test sets `_FakeClient.next_payload`
    before invoking the function under test."""

    next_payload: dict | None = None
    last_request_body: dict | None = None

    def __init__(self, *args, **kwargs):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def post(self, url: str, *, headers: dict, json: dict):
        type(self).last_request_body = json
        return _FakeResponse(type(self).next_payload or {})


def _patch_provider(monkeypatch, *, openai_payload: dict | None = None):
    """Monkeypatch the OpenAI route. Anthropic could be patched the same way
    but isn't needed for these tests."""
    _FakeClient.next_payload = openai_payload or {}
    _FakeClient.last_request_body = None
    monkeypatch.setattr("app.services.vision_ai.httpx.Client", _FakeClient)
    monkeypatch.setattr(
        "app.services.vision_ai.resolve_direct_api_key",
        lambda *a, **k: "fake-key",
    )
    monkeypatch.setattr(
        "app.services.vision_ai.direct_provider_availability",
        lambda name, **k: (name == "openai", "server_key"),
    )
    monkeypatch.setattr(
        "app.services.vision_ai.resolve_direct_model",
        lambda name, **k: "gpt-5.4-mini",
    )


def test_identify_ingredient_parses_strict_json(monkeypatch):
    expected = {
        "name": "habanero pepper",
        "confidence": "high",
        "common_names": ["habanero", "scotch bonnet"],
        "cuisine_uses": [
            {"country": "Mexico", "dish": "salsa habanera"},
            {"country": "Caribbean", "dish": "jerk seasoning"},
        ],
        "recipe_match_terms": ["habanero", "chili pepper", "hot pepper"],
        "notes": "Very spicy — handle with gloves.",
    }
    _patch_provider(
        monkeypatch,
        openai_payload={
            "choices": [{"message": {"content": json.dumps(expected)}}]
        },
    )
    result = identify_ingredient(
        image_bytes=b"\x89PNG\r\n",
        mime_type="image/png",
        settings=_settings(),
        user_settings={},
    )
    assert isinstance(result, IngredientIdentification)
    assert result.name == "habanero pepper"
    assert result.confidence == "high"
    assert len(result.cuisine_uses) == 2
    assert result.cuisine_uses[0].country == "Mexico"
    assert "habanero" in result.recipe_match_terms

    # The image should be sent as a base64 data URL inside the user content.
    body = _FakeClient.last_request_body
    assert body is not None
    user_msg = body["messages"][1]
    assert user_msg["role"] == "user"
    image_block = next(b for b in user_msg["content"] if b["type"] == "image_url")
    assert image_block["image_url"]["url"].startswith("data:image/png;base64,")


def test_identify_ingredient_rejects_oversized_image(monkeypatch):
    _patch_provider(monkeypatch)
    with pytest.raises(ValueError, match="Image is too large"):
        identify_ingredient(
            image_bytes=b"x" * (MAX_IMAGE_BYTES + 1),
            mime_type="image/jpeg",
            settings=_settings(),
            user_settings={},
        )


def test_identify_ingredient_rejects_unknown_mime(monkeypatch):
    _patch_provider(monkeypatch)
    with pytest.raises(ValueError, match="Unsupported image MIME type"):
        identify_ingredient(
            image_bytes=b"data",
            mime_type="application/pdf",
            settings=_settings(),
            user_settings={},
        )


def test_identify_ingredient_raises_on_bad_json(monkeypatch):
    _patch_provider(
        monkeypatch,
        openai_payload={"choices": [{"message": {"content": "not json at all"}}]},
    )
    with pytest.raises(RuntimeError, match="invalid JSON"):
        identify_ingredient(
            image_bytes=b"\x89PNG",
            mime_type="image/png",
            settings=_settings(),
            user_settings={},
        )


def test_check_cooking_progress_parses_strict_json(monkeypatch):
    expected = {
        "verdict": "needs_more_time",
        "tip": "The onions look pale — give them another 3 minutes until golden.",
        "suggested_minutes_remaining": 3,
    }
    _patch_provider(
        monkeypatch,
        openai_payload={
            "choices": [{"message": {"content": json.dumps(expected)}}]
        },
    )
    result = check_cooking_progress(
        image_bytes=b"\x89PNG",
        mime_type="image/png",
        recipe_title="French onion soup",
        step_text="Caramelize the onions until deep golden brown.",
        recipe_context="Yields 4 servings.",
        settings=_settings(),
        user_settings={},
    )
    assert isinstance(result, CookCheckTip)
    assert result.verdict == "needs_more_time"
    assert result.suggested_minutes_remaining == 3


def test_check_cooking_progress_heic_falls_back_to_jpeg_for_openai(monkeypatch):
    """OpenAI doesn't accept image/heic, so the runner re-labels it as
    image/jpeg before sending. This relies on the iOS client transcoding
    the bytes to JPEG, which it does — this guard is belt-and-suspenders."""
    _patch_provider(
        monkeypatch,
        openai_payload={
            "choices": [
                {
                    "message": {
                        "content": json.dumps(
                            {
                                "verdict": "on_track",
                                "tip": "Looks great.",
                                "suggested_minutes_remaining": 0,
                            }
                        )
                    }
                }
            ]
        },
    )
    check_cooking_progress(
        image_bytes=b"\xff\xd8\xff",
        mime_type="image/heic",
        recipe_title="Roast chicken",
        step_text="Roast for 1 hour at 425°F.",
        recipe_context="",
        settings=_settings(),
        user_settings={},
    )
    body = _FakeClient.last_request_body
    image_block = next(
        b for b in body["messages"][1]["content"] if b["type"] == "image_url"
    )
    assert image_block["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_resolves_anthropic_when_only_anthropic_configured(monkeypatch):
    """When only Anthropic has a key, the runner builds the image content
    block with Anthropic's `image` source format."""
    captured: dict[str, dict] = {}

    class _AnthropicFake:
        def __init__(self, *a, **k):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *a):
            pass

        def post(self, url, *, headers, json):
            captured["url"] = {"url": url}
            captured["body"] = json
            return _FakeResponse(
                {
                    "content": [
                        {
                            "type": "text",
                            "text": '{"name":"basil","confidence":"high",'
                            '"common_names":[],"cuisine_uses":[],'
                            '"recipe_match_terms":["basil"],"notes":""}',
                        }
                    ]
                }
            )

    monkeypatch.setattr("app.services.vision_ai.httpx.Client", _AnthropicFake)
    monkeypatch.setattr(
        "app.services.vision_ai.resolve_direct_api_key",
        lambda *a, **k: "fake-anthropic-key",
    )
    monkeypatch.setattr(
        "app.services.vision_ai.direct_provider_availability",
        lambda name, **k: (name == "anthropic", "server_key"),
    )
    monkeypatch.setattr(
        "app.services.vision_ai.resolve_direct_model",
        lambda name, **k: "claude-3-5-sonnet-latest",
    )

    result = identify_ingredient(
        image_bytes=b"\x89PNG\r\n",
        mime_type="image/png",
        settings=_settings(),
        user_settings={"ai_direct_provider": "anthropic"},
    )
    assert result.name == "basil"
    assert captured["url"]["url"] == "https://api.anthropic.com/v1/messages"
    user_msg = captured["body"]["messages"][0]
    image_block = next(b for b in user_msg["content"] if b["type"] == "image")
    assert image_block["source"]["type"] == "base64"
    assert image_block["source"]["media_type"] == "image/png"
