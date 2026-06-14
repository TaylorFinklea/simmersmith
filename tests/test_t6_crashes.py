"""T6 — crashes / dead features (2026-06-13 bug bash).

#18 rebalance-day endpoint AttributeError (WeekMealIngredient.meal_id),
#3  cancelled assistant turn makes the thread un-loadable (status not in Literal),
#33 recipe import 500 on a "1/0" quantity (ZeroDivisionError),
#1  kid-friendly variation preset corrupts steps/ingredients (missing tuple comma).
"""
from __future__ import annotations

from datetime import date

from app.db import session_scope
from app.models._base import new_id
from app.models.week import Week, WeekMeal


# ── #18 — rebalance-day endpoint reaches the AI call (was AttributeError 500) ──


def test_rebalance_day_does_not_attributeerror(client, monkeypatch) -> None:
    def _stop(**kwargs):
        raise RuntimeError("mock-rebalance-stop")

    monkeypatch.setattr("app.services.week_planner.rebalance_day", _stop)

    # A dietary goal is required before rebalancing.
    client.put(
        "/api/profile/dietary-goal",
        json={"goal_type": "maintain", "daily_calories": 2000, "protein_g": 150, "carbs_g": 200, "fat_g": 60},
    )
    body = client.post("/api/weeks", json={"week_start": "2026-09-21", "notes": ""}).json()
    week_id = body.get("week_id") or body["id"]
    target = date(2026, 9, 21)
    with session_scope() as session:
        week = session.scalar(Week.__table__.select().where(Week.id == week_id))  # type: ignore[arg-type]
        session.add(
            WeekMeal(id=new_id(), week_id=week_id, day_name="Monday", meal_date=target, slot="dinner", recipe_name="Old Dinner", source="ai")
        )
        assert week is not None

    r = client.post(f"/api/weeks/{week_id}/days/rebalance", json={"meal_date": "2026-09-21"})
    # Pre-fix: the delete loop hit WeekMealIngredient.meal_id -> AttributeError ->
    # 500. Post-fix it reaches run_rebalance, whose mocked RuntimeError -> 422.
    assert r.status_code == 422
    assert "mock-rebalance-stop" in r.json()["detail"]


# ── #3 — a cancelled message keeps the thread readable (was 500) ──────


def test_cancelled_assistant_message_thread_is_readable(client) -> None:
    from app.config import get_settings
    from app.services.assistant_threads import create_message, create_thread

    user_id = get_settings().local_user_id
    with session_scope() as session:
        thread = create_thread(session, user_id, title="cancel test")
        create_message(session, thread=thread, role="user", status="completed", content_markdown="plan it")
        create_message(session, thread=thread, role="assistant", status="cancelled", content_markdown="partial…")
        thread_id = thread.id

    r = client.get(f"/api/assistant/threads/{thread_id}")
    assert r.status_code == 200  # was 500 — "cancelled" wasn't in the status Literal
    statuses = [m["status"] for m in r.json()["messages"]]
    assert "cancelled" in statuses


# ── #33 — recipe import quantity parser survives a zero denominator ───


def test_parse_quantity_zero_denominator_returns_none() -> None:
    from app.services.recipe_import.ingredient_normalizer import (
        consume_quantity_prefix,
        parse_quantity_text,
    )

    assert parse_quantity_text("1/0") is None  # was ZeroDivisionError
    assert parse_quantity_text("2 1/0") is None
    # The unparseable token stays part of the line rather than crashing import.
    qty, rest = consume_quantity_prefix("1/0 cup flour")
    assert qty is None
    assert "flour" in rest
    # A valid fraction still parses.
    assert parse_quantity_text("1/2") == 0.5


# ── #1 — kid-friendly variation no longer iterates the chars of "onion" ──


def test_kid_friendly_onion_rule_is_a_tuple() -> None:
    from app.services.recipe_ai import VARIATION_PRESETS

    kid = next(p for p in VARIATION_PRESETS if p.key == "kid_friendly")
    onion_rule = next(r for r in kid.ingredient_rules if "onion" in r.terms)
    assert onion_rule.terms == ("onion",)  # a 1-tuple, not the string "onion"


def test_kid_friendly_variation_does_not_corrupt_steps_or_ingredients() -> None:
    from app.schemas import RecipeIngredientPayload, RecipePayload, RecipeStepPayload
    from app.services.recipe_ai import build_variation_draft

    base = RecipePayload(
        name="Chicken Skillet",
        ingredients=[
            RecipeIngredientPayload(ingredient_name="chicken breast"),
            RecipeIngredientPayload(ingredient_name="onion"),
        ],
        steps=[RecipeStepPayload(sort_order=1, instruction="Bring water to a boil, then add rice.")],
    )

    draft, _summary, _label = build_variation_draft(base, goal="Kid-Friendly")
    names = [i.ingredient_name for i in draft.ingredients]
    step_text = draft.steps[0].instruction

    # Pre-fix, iterating the chars of "onion" replaced every o/n/i and mangled
    # all of these. Post-fix only the literal word "onion" is rewritten.
    assert "chicken breast" in names
    assert "finely diced onion" in names  # the rule still works on real onion
    assert step_text == "Bring water to a boil, then add rice."
