"""M26 Phase 4 — per-dish event recipe linking + AI-generated drafts.

Two flows under test:
1. PATCHing an event meal with a `recipe_id` links it to an existing
   recipe (already supported by M10 schema; we verify the route works
   for the M26 use-case).
2. POSTing to `/ai-recipe` returns a complete `RecipePayload`-shaped
   draft for ONE dish, with the AI provider mocked.
"""
from __future__ import annotations

import json as _json


def _create_event(client) -> dict:
    sue = client.post(
        "/api/guests",
        json={"name": "Aunt Sue", "allergies": "gluten"},
    ).json()
    event = client.post(
        "/api/events",
        json={
            "name": "Family Lunch",
            "event_date": "2026-06-13",
            "occasion": "casual",
            "attendee_count": 6,
            "attendees": [{"guest_id": sue["guest_id"]}],
        },
    ).json()
    # Inline meal-create isn't supported by the events POST schema —
    # add it explicitly via the meals route, mirroring the iOS flow.
    return client.post(
        f"/api/events/{event['event_id']}/meals",
        json={
            "role": "side",
            "recipe_name": "Cheesy potatoes",
            "servings": 6,
        },
    ).json()


def test_event_meal_link_to_existing_recipe(client) -> None:
    """PATCH .../meals/{id} with a `recipe_id` links the event meal to
    a recipe in the same household."""
    # Create a recipe to link to.
    recipe = client.post(
        "/api/recipes",
        json={
            "name": "Cheesy potatoes (household)",
            "meal_type": "side",
            "servings": 6,
            "ingredients": [
                {"ingredient_name": "Yukon golds", "quantity": 3, "unit": "lb"},
            ],
        },
    ).json()
    event = _create_event(client)
    meal = event["meals"][0]

    resp = client.patch(
        f"/api/events/{event['event_id']}/meals/{meal['meal_id']}",
        json={"recipe_id": recipe["recipe_id"]},
    )
    assert resp.status_code == 200, resp.text
    updated = resp.json()
    relinked = next(m for m in updated["meals"] if m["meal_id"] == meal["meal_id"])
    assert relinked["recipe_id"] == recipe["recipe_id"]


def test_event_meal_ai_recipe_generates_draft(client, monkeypatch) -> None:
    """POST /ai-recipe returns a RecipePayload-shaped draft using the
    mocked AI provider; the route does NOT persist a Recipe."""
    fake_response = _json.dumps({
        "name": "Cheesy potatoes (gluten-free)",
        "meal_type": "side",
        "cuisine": "american",
        "servings": 6,
        "prep_minutes": 15,
        "cook_minutes": 45,
        "tags": ["gluten-free"],
        "instructions_summary": "Layer + bake.",
        "ingredients": [
            {"ingredient_name": "Yukon golds", "quantity": 3, "unit": "lb"},
            {"ingredient_name": "Cheddar", "quantity": 8, "unit": "oz"},
        ],
        "steps": [
            {"order_index": 1, "instruction": "Slice potatoes thin."},
            {"order_index": 2, "instruction": "Layer with cheese, bake at 375."},
        ],
    })

    def fake_run_direct_provider(*, target, settings, user_settings, prompt):  # noqa: ARG001
        assert "Cheesy potatoes" in prompt
        assert "Aunt Sue" in prompt or "gluten" in prompt
        return fake_response

    def fake_availability(name, *, settings, user_settings):  # noqa: ARG001
        return (True, "env") if name == "openai" else (False, "unset")

    monkeypatch.setattr("app.services.event_ai.run_direct_provider", fake_run_direct_provider)
    monkeypatch.setattr("app.services.event_ai.direct_provider_availability", fake_availability)
    monkeypatch.setattr(
        "app.services.event_ai.resolve_direct_model",
        lambda name, *, settings, user_settings: "gpt-test",  # noqa: ARG005
    )

    event = _create_event(client)
    meal = event["meals"][0]

    resp = client.post(
        f"/api/events/{event['event_id']}/meals/{meal['meal_id']}/ai-recipe",
        json={"prompt": "make it gluten-free", "servings": 0},
    )
    assert resp.status_code == 200, resp.text
    draft = resp.json()
    assert draft["name"] == "Cheesy potatoes (gluten-free)"
    assert draft["servings"] == 6
    assert any(ing["ingredient_name"] == "Yukon golds" for ing in draft["ingredients"])
    assert len(draft["steps"]) == 2

    # Important: the draft is NOT persisted as a real Recipe — the
    # human-in-the-loop pattern means the iOS client decides whether
    # to save it. Verify by listing recipes.
    recipes = client.get("/api/recipes").json()
    assert not any(r["name"] == "Cheesy potatoes (gluten-free)" for r in recipes)


def test_event_meal_ai_recipe_404_unknown_meal(client) -> None:
    event = _create_event(client)
    resp = client.post(
        f"/api/events/{event['event_id']}/meals/does-not-exist/ai-recipe",
        json={"prompt": "anything", "servings": 4},
    )
    assert resp.status_code == 404
