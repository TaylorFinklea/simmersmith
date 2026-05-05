"""M29 build 53 — `/api/weeks/.../sides/{id}/ai-recipe` route.

Generates a draft for a side, scaled to the parent meal's servings.
Returns the draft only — never persists. iOS routes through the
review sheet, then on Save the existing PATCH side route links the
saved recipe.
"""
from __future__ import annotations

import json as _json
from datetime import date

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import Recipe, WeekMeal, WeekMealSide
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.sides import add_side
from app.services.weeks import create_or_get_week

_uid = get_settings().local_user_id


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


def _seed_week_meal_side(session, *, week_start: date):
    week = create_or_get_week(
        session,
        user_id=_uid,
        household_id=_uid,
        week_start=week_start,
        notes="side AI test",
    )
    apply_ai_draft(
        session,
        week,
        DraftFromAIRequest(
            prompt="dinner",
            recipes=[
                RecipePayload(
                    recipe_id="lasagna",
                    name="Lasagna",
                    meal_type="dinner",
                    servings=4,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Noodles", quantity=1, unit="lb"),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Wednesday",
                    meal_date=week_start,
                    slot="dinner",
                    recipe_id="lasagna",
                    recipe_name="Lasagna",
                    servings=4,
                ),
            ],
        ),
    )
    meal = session.scalar(select(WeekMeal).where(WeekMeal.week_id == week.id))
    side = add_side(
        session,
        week=week,
        meal=meal,
        household_id=_uid,
        name="Garlic bread",
        recipe_id=None,
        user_id=_uid,
    )
    session.commit()
    return week, meal, side


def test_side_ai_recipe_returns_draft_no_persist(client, monkeypatch) -> None:
    draft_payload = {
        "name": "Garlic bread",
        "meal_type": "side",
        "cuisine": "italian",
        "servings": 4,
        "prep_minutes": 10,
        "cook_minutes": 15,
        "tags": [],
        "instructions_summary": "",
        "ingredients": [
            {"ingredient_name": "Baguette", "quantity": 1, "unit": "ea"},
            {"ingredient_name": "Garlic", "quantity": 4, "unit": "clove"},
        ],
        "steps": [{"order_index": 1, "instruction": "Slice + toast."}],
    }
    _patch_provider(monkeypatch, draft_payload)

    with session_scope() as session:
        week, meal, side = _seed_week_meal_side(session, week_start=date(2026, 5, 13))
        week_id, meal_id, side_id = week.id, meal.id, side.id
        side_name = side.name

    resp = client.post(
        f"/api/weeks/{week_id}/meals/{meal_id}/sides/{side_id}/ai-recipe",
        json={"prompt": "make it cheesy", "servings": 0},
    )
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["name"] == "Garlic bread"
    assert out["servings"] == 4  # falls back to parent meal's servings

    # Critical: no Recipe row was persisted. The iOS Save flow is
    # the only persistence path — verify it stayed clean.
    with session_scope() as session:
        names = [r.name for r in session.scalars(select(Recipe)).all()]
    assert side_name not in names


def test_side_ai_recipe_404_unknown_side(client) -> None:
    """Bad side id returns 404 — important so iOS doesn't show a
    spinner that never resolves."""
    with session_scope() as session:
        week, meal, _side = _seed_week_meal_side(session, week_start=date(2026, 5, 20))
        week_id, meal_id = week.id, meal.id

    resp = client.post(
        f"/api/weeks/{week_id}/meals/{meal_id}/sides/does-not-exist/ai-recipe",
        json={"prompt": "anything", "servings": 4},
    )
    assert resp.status_code == 404
