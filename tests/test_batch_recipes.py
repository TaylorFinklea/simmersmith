"""Recipes lane — bug-bash fixes (2026-06-13 report).

#31 split_summary_into_steps shreds single-paragraph summaries and drops
    embedded mid-sentence quantities/temps/times.
#50 apply_ai_draft orphans WeekMealSide rows on re-apply (SQLite/test path —
    Core bulk delete bypasses the FK CASCADE).
#54 opportunistic on-save image write can roll back the whole recipe save
    under a concurrent-create IntegrityError on the RecipeImage PK.
T7  HTTPException(detail=str(exc)) on the AI-provider 502 paths must not leak
    provider URLs / raw error bodies into user-facing responses.
"""
from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import RecipeImage, WeekMeal, WeekMealSide
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipePayload
from app.services.drafts import apply_ai_draft
from app.services.recipes import split_summary_into_steps
from app.services.weeks import create_or_get_week, get_week

_uid = get_settings().local_user_id


# ── #31 — single-paragraph summary keeps its embedded numbers ────────


def test_split_summary_keeps_mid_sentence_quantities() -> None:
    summary = "Brown 1 pound ground beef. Add 2 cans tomatoes and simmer 30 minutes."
    steps = split_summary_into_steps(summary)
    # Pre-fix this returned ['Brown', 'pound ground beef', 'Add',
    # 'cans tomatoes and simmer', 'minutes.'] — the digits were the split
    # boundary and were dropped. Post-fix it splits only on sentences.
    assert steps == [
        "Brown 1 pound ground beef",
        "Add 2 cans tomatoes and simmer 30 minutes.",
    ]
    joined = " ".join(steps)
    assert "1 pound" in joined
    assert "2 cans" in joined
    assert "30 minutes" in joined


def test_split_summary_strips_leading_numbered_marker_per_sentence() -> None:
    summary = "1. Preheat oven to 400 degrees. 2. Roast for 25 minutes."
    steps = split_summary_into_steps(summary)
    assert steps == ["Preheat oven to 400 degrees", "Roast for 25 minutes."]
    # The 400 and 25 are content, not delimiters, so they survive.
    assert "400 degrees" in steps[0]
    assert "25 minutes" in steps[1]


def test_split_summary_multiline_branch_unchanged() -> None:
    summary = "1) Chop 3 carrots\n2) Boil 2 cups water"
    assert split_summary_into_steps(summary) == ["Chop 3 carrots", "Boil 2 cups water"]


# ── #50 — re-applying a draft deletes the meal's sides (no orphans) ──


def test_apply_ai_draft_deletes_week_meal_sides() -> None:
    with session_scope() as session:
        week = create_or_get_week(
            session, user_id=_uid, household_id=_uid, week_start=date(2026, 5, 4), notes="sides"
        )
        # Seed a meal with a side, the way the user would after the first draft.
        meal = WeekMeal(
            week_id=week.id,
            day_name="Monday",
            meal_date=date(2026, 5, 4),
            slot="dinner",
            recipe_name="Roast Chicken",
            source="ai",
        )
        session.add(meal)
        session.flush()
        session.add(WeekMealSide(week_meal_id=meal.id, name="Garlic Bread"))
        session.flush()
        old_meal_id = meal.id

        payload = DraftFromAIRequest(
            prompt="Re-plan the week.",
            meal_plan=[
                MealDraftPayload(
                    day_name="Tuesday",
                    meal_date=date(2026, 5, 5),
                    slot="dinner",
                    recipe_name="Pasta",
                    servings=2,
                )
            ],
        )
        apply_ai_draft(session, week, payload)
        session.flush()

        # Pre-fix: the WeekMealSide row pointing at the deleted meal survived
        # the Core bulk delete (SQLite FK enforcement off), orphaning it.
        orphaned = session.scalars(
            select(WeekMealSide).where(WeekMealSide.week_meal_id == old_meal_id)
        ).all()
        assert orphaned == []

        live_meal_ids = {
            row for row in session.scalars(select(WeekMeal.id).where(WeekMeal.week_id == week.id))
        }
        # Every remaining side must reference a live meal.
        for side in session.scalars(select(WeekMealSide)):
            assert side.week_meal_id in live_meal_ids

    with session_scope() as session:
        refreshed = get_week(session, _uid, week.id)
        assert refreshed is not None
        assert {m.recipe_name for m in refreshed.meals} == {"Pasta"}


# ── #54 — image-write IntegrityError can't roll back the recipe save ──


def test_save_recipe_survives_image_write_conflict(client, monkeypatch) -> None:
    monkeypatch.setattr("app.api.recipes.is_image_gen_configured", lambda *a, **k: True)
    monkeypatch.setattr(
        "app.api.recipes.generate_recipe_image",
        lambda *a, **k: (b"\x89PNG\r\n\x1a\n", "image/png", "prompt", "openai", "gpt-image-1"),
    )
    # Pre-seed the image row so the save's image INSERT conflicts on the
    # RecipeImage PK, and force `persist_recipe_image` down the unconditional
    # INSERT branch — the exact concurrent-create race where both savers skip
    # the existence check and both add a row.
    def _always_insert(session, recipe_id, image_bytes, mime_type, prompt):
        session.add(
            RecipeImage(recipe_id=recipe_id, image_bytes=image_bytes, mime_type=mime_type, prompt=prompt)
        )

    monkeypatch.setattr("app.api.recipes.persist_recipe_image", _always_insert)
    monkeypatch.setattr("app.api.recipes.recipe_has_image", lambda *a, **k: False)

    body = {"recipe_id": "race-recipe", "name": "Race Recipe", "servings": 2}

    first = client.post("/api/recipes", json=body)
    assert first.status_code == 200

    # The image row now exists; the next save's image write adds a duplicate PK.
    # Pre-fix that IntegrityError poisoned the session and the recipe save's
    # commit re-raised (500). Post-fix the savepoint isolates it and the recipe
    # save still succeeds.
    second = client.post("/api/recipes", json={**body, "notes": "second save"})
    assert second.status_code == 200
    assert second.json()["notes"] == "second save"

    with session_scope() as session:
        images = session.scalars(
            select(RecipeImage).where(RecipeImage.recipe_id == "race-recipe")
        ).all()
        assert len(images) == 1


# ── T7 — provider error strings don't leak into the 502 response ─────


def test_pairings_502_does_not_leak_provider_url(client, monkeypatch) -> None:
    payload = RecipePayload(recipe_id="leak-recipe", name="Leak Recipe", servings=2)
    save = client.post("/api/recipes", json=payload.model_dump(mode="json"))
    assert save.status_code == 200
    recipe_id = save.json()["recipe_id"]

    def _boom(**kwargs):
        raise RuntimeError(
            "AI provider request failed: Client error '401 Unauthorized' for url "
            "'https://api.openai.com/v1/chat/completions'"
        )

    monkeypatch.setattr("app.services.pairing_ai.suggest_pairings", _boom)

    resp = client.post(f"/api/recipes/{recipe_id}/pairings")
    assert resp.status_code == 502
    detail = resp.json()["detail"]
    assert "api.openai.com" not in detail
    assert "401" not in detail
    assert "url" not in detail.lower()
