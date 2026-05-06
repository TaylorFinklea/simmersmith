"""Build 57 — `quick` recipe tag.

The tag is auto-applied by the AI prompt (instructed to add `"quick"`
to `tags` when `prep_minutes + cook_minutes <= 30`) AND can be set
manually by the user in the iOS recipe editor. The iOS Quick filter
pill matches either path: `tags.contains("quick") || (prep+cook ≤ 30)`.

These tests verify the backend half:
- The drafting prompt explicitly carries the quick-tag rule.
- A draft returned with a "quick" tag round-trips intact through the
  refine route.
- The refine prompt also instructs re-evaluation after a tweak.
"""
from __future__ import annotations

import json as _json


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


def test_dish_prompt_contains_quick_tag_rule() -> None:
    """The drafting prompt must instruct the AI to include the
    `quick` tag for short recipes — that's the auto-tag pathway."""
    from app.services.recipe_drafting import _build_dish_prompt

    prompt = _build_dish_prompt(
        dish_name="Sheet-pan chicken",
        servings=4,
        user_prompt="weeknight",
        constraints_block="",
        context_label="a Tuesday dinner",
        user_settings={},
    )
    assert "quick" in prompt.lower()
    assert "30" in prompt  # the threshold itself, not just the word


def test_refine_prompt_re_evaluates_quick_tag() -> None:
    """A refine that meaningfully changes prep/cook time must
    prompt the AI to re-decide whether `quick` still applies."""
    from app.services.recipe_drafting import refine_recipe_draft, _SCHEMA_HINT

    captured = {"prompt": ""}

    def fake_provider(*, target, settings, user_settings, prompt):
        captured["prompt"] = prompt
        return _json.dumps(
            {
                "name": "Sheet-pan chicken",
                "servings": 4,
                "prep_minutes": 5,
                "cook_minutes": 20,
                "tags": ["quick"],
                "ingredients": [],
                "steps": [],
            }
        )

    import app.services.recipe_drafting as drafting

    original_provider = drafting.run_direct_provider
    original_availability = None
    original_resolve = None
    try:
        drafting.run_direct_provider = fake_provider  # type: ignore[assignment]
        from app.services import event_ai

        original_availability = event_ai.direct_provider_availability
        original_resolve = event_ai.resolve_direct_model
        event_ai.direct_provider_availability = (  # type: ignore[assignment]
            lambda name, *, settings, user_settings: (True, "env")
            if name == "openai"
            else (False, "unset")
        )
        event_ai.resolve_direct_model = (  # type: ignore[assignment]
            lambda name, *, settings, user_settings: "gpt-test"
        )

        from app.config import get_settings

        result = refine_recipe_draft(
            settings=get_settings(),
            user_settings={},
            draft={
                "name": "Sheet-pan chicken",
                "prep_minutes": 5,
                "cook_minutes": 20,
                "servings": 4,
                "tags": [],
                "ingredients": [],
                "steps": [],
            },
            prompt="add a quick rice side",
            context_hint="",
        )
    finally:
        drafting.run_direct_provider = original_provider  # type: ignore[assignment]
        if original_availability is not None:
            from app.services import event_ai

            event_ai.direct_provider_availability = original_availability  # type: ignore[assignment]
        if original_resolve is not None:
            from app.services import event_ai

            event_ai.resolve_direct_model = original_resolve  # type: ignore[assignment]

    assert "quick" in captured["prompt"].lower()
    assert "30" in captured["prompt"]
    assert "quick" in result.get("tags", [])
    assert _SCHEMA_HINT in captured["prompt"]


def test_quick_draft_round_trips_through_refine_route(client, monkeypatch) -> None:
    """End-to-end via the HTTP route: the AI returns a fast recipe
    with the `quick` tag and it crosses the API boundary intact."""
    refined = {
        "name": "5-minute couscous",
        "meal_type": "dinner",
        "cuisine": "mediterranean",
        "servings": 2,
        "prep_minutes": 5,
        "cook_minutes": 10,
        "tags": ["quick", "vegetarian"],
        "instructions_summary": "Boil + fluff.",
        "ingredients": [
            {"ingredient_name": "Couscous", "quantity": 1, "unit": "cup"},
        ],
        "steps": [{"order_index": 1, "instruction": "Boil water."}],
    }
    _patch_provider(monkeypatch, refined)

    base = {
        "name": "Couscous",
        "servings": 2,
        "prep_minutes": 5,
        "cook_minutes": 10,
        "tags": [],
        "ingredients": [],
        "steps": [],
    }
    resp = client.post(
        "/api/recipes/draft/refine",
        json={"draft": base, "prompt": "make it more flavorful", "context_hint": ""},
    )
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert "quick" in out["tags"]
    assert (out["prep_minutes"] or 0) + (out["cook_minutes"] or 0) <= 30
