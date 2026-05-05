"""M26 Phase 5 — assistant dry-run confirm flow.

`swap_meal` returns a `proposed_change` payload without applying.
`confirm_swap_meal` applies the same args. `cancel_swap_meal` no-ops
so the LLM closes the loop cleanly.
"""
from __future__ import annotations

from datetime import date

from app.config import get_settings
from app.db import session_scope
from app.models import WeekMeal
from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipePayload, RecipeIngredientPayload
from app.services.assistant_tools import run_tool
from app.services.drafts import apply_ai_draft
from app.services.weeks import create_or_get_week, get_week
from sqlalchemy import select

_uid = get_settings().local_user_id


def _seed_week(session, *, week_start: date):
    week = create_or_get_week(
        session,
        user_id=_uid,
        household_id=_uid,
        week_start=week_start,
        notes="dry-run test",
    )
    payload = DraftFromAIRequest(
        prompt="dinner-only week",
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
    )
    apply_ai_draft(session, week, payload)
    meal = session.scalar(select(WeekMeal).where(WeekMeal.week_id == week.id))
    return week, meal


def test_swap_meal_returns_proposed_change_without_mutating() -> None:
    settings = get_settings()
    with session_scope() as session:
        week, meal = _seed_week(session, week_start=date(2026, 6, 17))
        original_name = meal.recipe_name

        result = run_tool(
            "swap_meal",
            session=session,
            user_id=_uid,
            household_id=_uid,
            linked_week_id=week.id,
            args={"meal_id": meal.id, "recipe_name": "Sheet-Pan Salmon"},
            settings=settings,
        )

        assert result.ok is True, result.detail
        assert result.data.get("kind") == "proposed_change"
        assert result.data["before"]["recipe_name"] == "Lasagna"
        assert result.data["after"]["recipe_name"] == "Sheet-Pan Salmon"
        assert result.data["confirm_tool"] == "confirm_swap_meal"
        # Critical: NO mutation happened. The DB still has Lasagna.
        refreshed = get_week(session, _uid, week.id)
        unchanged = next(m for m in refreshed.meals if m.id == meal.id)
        assert unchanged.recipe_name == original_name


def test_confirm_swap_meal_applies_the_change() -> None:
    settings = get_settings()
    with session_scope() as session:
        week, meal = _seed_week(session, week_start=date(2026, 6, 24))

        # First propose (no mutation).
        propose = run_tool(
            "swap_meal",
            session=session,
            user_id=_uid,
            household_id=_uid,
            linked_week_id=week.id,
            args={"meal_id": meal.id, "recipe_name": "Sheet-Pan Salmon"},
            settings=settings,
        )
        assert propose.ok is True

        # Then confirm with the same args.
        result = run_tool(
            "confirm_swap_meal",
            session=session,
            user_id=_uid,
            household_id=_uid,
            linked_week_id=week.id,
            args={"meal_id": meal.id, "recipe_name": "Sheet-Pan Salmon"},
            settings=settings,
        )
        assert result.ok is True, result.detail
        assert result.week is not None

        refreshed = get_week(session, _uid, week.id)
        applied = next(m for m in refreshed.meals if m.id == meal.id)
        assert applied.recipe_name == "Sheet-Pan Salmon"


def test_cancel_swap_meal_is_a_noop() -> None:
    settings = get_settings()
    with session_scope() as session:
        week, meal = _seed_week(session, week_start=date(2026, 7, 1))
        original_name = meal.recipe_name

        result = run_tool(
            "cancel_swap_meal",
            session=session,
            user_id=_uid,
            household_id=_uid,
            linked_week_id=week.id,
            args={"summary": "Wednesday dinner swap"},
            settings=settings,
        )
        assert result.ok is True
        assert "declined" in result.detail.lower()

        refreshed = get_week(session, _uid, week.id)
        unchanged = next(m for m in refreshed.meals if m.id == meal.id)
        assert unchanged.recipe_name == original_name
