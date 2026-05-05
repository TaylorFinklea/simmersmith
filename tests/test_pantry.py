"""M28 — pantry CRUD + recurring fold-in.

The existing staple-filter behavior is regression-tested in
`test_grocery.py::test_grocery_aggregation_excludes_default_staples`
— this file focuses on the new pantry surfaces:

- pantry items still get filtered from meal-driven aggregation
- recurring pantry items land as user_added grocery rows
- biweekly cadence skips weeks before the gap is met
- re-running apply is idempotent
- updates patch in place (recurring metadata survives partial saves)
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import GroceryItem, Staple
from app.services.grocery import regenerate_grocery_for_week
from app.services.pantry import (
    add_pantry_item,
    apply_pantry_recurrings,
    update_pantry_item,
)
from app.services.weeks import create_or_get_week, get_week

_uid = get_settings().local_user_id


def test_recurring_weekly_pantry_item_lands_in_grocery() -> None:
    with session_scope() as session:
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 6, 1),
            notes="pantry test",
        )
        add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Eggs",
            recurring_quantity=60.0,
            recurring_unit="ct",
            recurring_cadence="weekly",
            category="dairy",
        )
        apply_pantry_recurrings(session, week=week, household_id=_uid)

        rows = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.is_user_added.is_(True),
                )
            ).all()
        )

    assert len(rows) == 1
    eggs = rows[0]
    assert eggs.ingredient_name == "Eggs"
    assert eggs.total_quantity == 60.0
    assert eggs.unit == "ct"
    assert eggs.source_meals.startswith("pantry:recurring:")


def test_apply_pantry_recurrings_is_idempotent() -> None:
    """Calling apply twice doesn't double up the grocery rows."""
    with session_scope() as session:
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 6, 8),
            notes="idempotent test",
        )
        add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Milk",
            recurring_quantity=2.0,
            recurring_unit="gal",
            recurring_cadence="weekly",
        )
        apply_pantry_recurrings(session, week=week, household_id=_uid)
        apply_pantry_recurrings(session, week=week, household_id=_uid)

        rows = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.source_meals.like("pantry:recurring:%"),
                )
            ).all()
        )

    assert len(rows) == 1


def test_biweekly_cadence_skips_until_gap_met() -> None:
    """A biweekly recurring shouldn't add to a week within 13 days of
    the prior application; weekly bumps the timestamp on every run."""
    now = datetime.now(timezone.utc)
    with session_scope() as session:
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 6, 15),
            notes="cadence test",
        )
        item = add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Costco rotisserie",
            recurring_quantity=1.0,
            recurring_unit="ea",
            recurring_cadence="biweekly",
        )
        # Fake a prior apply 5 days ago — biweekly needs 13+.
        item.last_applied_at = now - timedelta(days=5)
        session.flush()

        apply_pantry_recurrings(session, week=week, household_id=_uid, now=now)
        early = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.source_meals.like("pantry:recurring:%"),
                )
            ).all()
        )
        assert len(early) == 0

        # Move the clock forward — now we're past the 13-day gap.
        future = now + timedelta(days=14)
        apply_pantry_recurrings(session, week=week, household_id=_uid, now=future)
        landed = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.source_meals.like("pantry:recurring:%"),
                )
            ).all()
        )
    assert len(landed) == 1


def test_pantry_items_still_filter_from_meal_aggregation() -> None:
    """Items in pantry must NOT auto-add via the meal-driven path,
    even when a meal needs them. This is the existing staple-filter
    behavior; we verify it still holds for pantry items with
    recurrings configured (recurring is a separate pathway)."""
    from app.schemas import DraftFromAIRequest, MealDraftPayload, RecipeIngredientPayload, RecipePayload
    from app.services.drafts import apply_ai_draft

    with session_scope() as session:
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 6, 22),
            notes="filter test",
        )
        # Eggs in pantry — should be filtered from grocery aggregation.
        add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Eggs",
            recurring_cadence="none",  # pure staple, no recurring
        )
        payload = DraftFromAIRequest(
            prompt="omelet week",
            recipes=[
                RecipePayload(
                    recipe_id="omelet",
                    name="Omelet",
                    meal_type="breakfast",
                    servings=2,
                    ingredients=[
                        RecipeIngredientPayload(ingredient_name="Eggs", quantity=4, unit="ea"),
                        RecipeIngredientPayload(ingredient_name="Bell pepper", quantity=1, unit="ea"),
                    ],
                ),
            ],
            meal_plan=[
                MealDraftPayload(
                    day_name="Monday",
                    meal_date=date(2026, 6, 22),
                    slot="breakfast",
                    recipe_id="omelet",
                    recipe_name="Omelet",
                    servings=2,
                ),
            ],
        )
        apply_ai_draft(session, week, payload)
        refreshed = get_week(session, _uid, week.id)

    names = {item.ingredient_name.lower() for item in refreshed.grocery_items}
    assert "eggs" not in names
    assert "bell pepper" in names


def test_pantry_update_patches_in_place() -> None:
    with session_scope() as session:
        item = add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Flour",
            typical_quantity=50.0,
            typical_unit="lb",
            recurring_cadence="none",
        )
        item_id = item.id
        # Add a recurring config without losing the typical_quantity.
        update_pantry_item(
            session,
            item=item,
            fields={
                "recurring_quantity": 5.0,
                "recurring_unit": "lb",
                "recurring_cadence": "monthly",
            },
        )
        refreshed = session.get(Staple, item_id)

    assert refreshed is not None
    assert refreshed.typical_quantity == 50.0
    assert refreshed.typical_unit == "lb"
    assert refreshed.recurring_quantity == 5.0
    assert refreshed.recurring_cadence == "monthly"


def test_regen_grocery_includes_pantry_recurring() -> None:
    """`regenerate_grocery_for_week` should run the pantry fold-in,
    so a fresh week (no manual apply call) still ends up with the
    recurring rows."""
    with session_scope() as session:
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 6, 29),
            notes="regen-includes-pantry",
        )
        add_pantry_item(
            session,
            user_id=_uid,
            household_id=_uid,
            name="Sourdough",
            recurring_quantity=1.0,
            recurring_unit="ea",
            recurring_cadence="weekly",
        )
        regenerate_grocery_for_week(session, _uid, _uid, week)
        rows = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.source_meals.like("pantry:recurring:%"),
                )
            ).all()
        )

    assert len(rows) == 1
    assert rows[0].ingredient_name == "Sourdough"
