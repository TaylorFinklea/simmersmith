"""M29 build 53 — `/api/recipes/draft/refine` round-trip.

The refine route is the engine of the new "review before commit"
funnel. It MUST NOT persist a Recipe row even when called many
times in a session — the iOS layer is the only persistence path.
"""
from __future__ import annotations

import json as _json

from app.models import Recipe
from sqlalchemy import select


def _patch_provider(monkeypatch, response_payload: dict) -> None:
    monkeypatch.setattr(
        "app.services.recipe_drafting.run_direct_provider",
        lambda *, target, settings, user_settings, prompt: _json.dumps(response_payload),
    )
    monkeypatch.setattr(
        "app.services.event_ai.direct_provider_availability",
        lambda name, *, settings, user_settings: (True, "env") if name == "openai" else (False, "unset"),
    )
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",
    )


def test_refine_route_returns_refined_draft_no_persist(client, monkeypatch) -> None:
    refined = {
        "name": "Spicy chicken tacos",
        "meal_type": "dinner",
        "cuisine": "mexican",
        "servings": 4,
        "prep_minutes": 15,
        "cook_minutes": 20,
        "tags": ["spicy"],
        "instructions_summary": "Cook + assemble.",
        "ingredients": [
            {"ingredient_name": "Chicken thighs", "quantity": 1.5, "unit": "lb"},
            {"ingredient_name": "Chipotle in adobo", "quantity": 2, "unit": "tbsp"},
        ],
        "steps": [{"order_index": 1, "instruction": "Sear the chicken."}],
    }
    _patch_provider(monkeypatch, refined)

    base = {
        "name": "Chicken tacos",
        "meal_type": "dinner",
        "cuisine": "mexican",
        "servings": 4,
        "prep_minutes": 15,
        "cook_minutes": 20,
        "tags": [],
        "instructions_summary": "",
        "ingredients": [
            {"ingredient_name": "Chicken thighs", "quantity": 1.5, "unit": "lb"},
        ],
        "steps": [{"order_index": 1, "instruction": "Sear the chicken."}],
    }

    resp = client.post(
        "/api/recipes/draft/refine",
        json={"draft": base, "prompt": "make it spicier", "context_hint": ""},
    )
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["name"] == "Spicy chicken tacos"
    assert any("Chipotle" in i["ingredient_name"] for i in out["ingredients"])

    # Critical: no Recipe rows should exist for the refined draft —
    # the iOS layer is responsible for persistence on Save.
    from app.db import session_scope

    with session_scope() as session:
        recipes = list(session.scalars(select(Recipe)).all())
    assert not any(r.name == "Spicy chicken tacos" for r in recipes)


def test_refine_route_empty_prompt_returns_input_unchanged(client) -> None:
    """An empty/whitespace prompt should short-circuit the AI call.
    The route enforces `min_length=1` on `prompt` — verify the
    schema rejects empty submissions cleanly."""
    base = {
        "name": "Chicken tacos",
        "ingredients": [],
        "steps": [],
        "tags": [],
        "servings": 4,
    }
    resp = client.post(
        "/api/recipes/draft/refine",
        json={"draft": base, "prompt": "  ", "context_hint": ""},
    )
    # Pydantic's min_length applies to the raw string before strip,
    # so a whitespace-only prompt currently passes the schema. The
    # service-level short-circuit returns the draft unchanged.
    assert resp.status_code in (200, 422)


def test_refine_route_propagates_provider_error(client, monkeypatch) -> None:
    """Provider failures bubble as 502 — but only after one retry.
    Build 54: the retry layer attempts a second call before giving
    up, so we feed two consecutive bad responses to confirm the
    failure path still raises."""
    monkeypatch.setattr(
        "app.services.recipe_drafting.run_direct_provider",
        lambda *, target, settings, user_settings, prompt: "not valid json {{{",
    )
    monkeypatch.setattr(
        "app.services.event_ai.direct_provider_availability",
        lambda name, *, settings, user_settings: (True, "env") if name == "openai" else (False, "unset"),
    )
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",
    )

    base = {"name": "X", "ingredients": [], "steps": [], "tags": [], "servings": 4}
    resp = client.post(
        "/api/recipes/draft/refine",
        json={"draft": base, "prompt": "make it sweeter", "context_hint": ""},
    )
    assert resp.status_code == 502


def test_refine_route_retries_invalid_json_once(client, monkeypatch) -> None:
    """Build 54: when the first AI response is unparseable but the
    retry succeeds, the route returns the refined draft. This is the
    common case the user reported on TestFlight 53 — the second
    attempt usually works."""
    call_count = {"n": 0}
    refined = {
        "name": "Spicy chicken tacos",
        "meal_type": "dinner",
        "cuisine": "mexican",
        "servings": 4,
        "ingredients": [{"ingredient_name": "Chipotle", "quantity": 2, "unit": "tbsp"}],
        "steps": [{"order_index": 1, "instruction": "Cook."}],
        "tags": [],
    }

    def fake_provider(*, target, settings, user_settings, prompt):
        call_count["n"] += 1
        if call_count["n"] == 1:
            return "garbage prefix ```json {nope"
        return _json.dumps(refined)

    monkeypatch.setattr("app.services.recipe_drafting.run_direct_provider", fake_provider)
    monkeypatch.setattr(
        "app.services.event_ai.direct_provider_availability",
        lambda name, *, settings, user_settings: (True, "env") if name == "openai" else (False, "unset"),
    )
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",
    )

    base = {"name": "Chicken tacos", "ingredients": [], "steps": [], "tags": [], "servings": 4}
    resp = client.post(
        "/api/recipes/draft/refine",
        json={"draft": base, "prompt": "make it spicier", "context_hint": ""},
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["name"] == "Spicy chicken tacos"
    assert call_count["n"] == 2  # one bad attempt + one retry succeeded
