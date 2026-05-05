"""M28 phase 2 — event pantry supplements.

A supplement says "for THIS event, I need extra of pantry item X
on top of normal household stock." It flows through the existing
event-grocery aggregation → week-grocery merge path with
event_quantity attribution. Recurring pantry restocks remain
intact alongside the supplement.
"""
from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import EventGroceryItem, EventPantrySupplement, GroceryItem
from app.services.event_grocery import apply_auto_merge_policy, regenerate_event_grocery
from app.services.event_supplements import (
    add_supplement,
    delete_supplement,
    update_supplement,
)
from app.services.events import create_event, get_event
from app.services.pantry import add_pantry_item
from app.services.weeks import create_or_get_week, get_week

_uid = get_settings().local_user_id


def _seed_event_with_pantry_item(session, *, event_name: str = "Easter Brunch"):
    pantry = add_pantry_item(
        session,
        user_id=_uid,
        household_id=_uid,
        name="Eggs",
        recurring_quantity=60.0,
        recurring_unit="ct",
        recurring_cadence="weekly",
        category="dairy",
    )
    event = create_event(
        session,
        user_id=_uid,
        household_id=_uid,
        name=event_name,
        event_date=date(2026, 4, 26),
        occasion="holiday",
        attendee_count=20,
        notes="",
        attendees=[],
    )
    return event, pantry


def test_supplement_lands_as_event_grocery_row() -> None:
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session)
        add_supplement(
            session,
            event=event,
            pantry_item_id=pantry.id,
            quantity=100.0,
            unit="ct",
            household_id=_uid,
        )
        regenerate_event_grocery(session, _uid, event)

        rows = list(
            session.scalars(
                select(EventGroceryItem).where(EventGroceryItem.event_id == event.id)
            ).all()
        )

    assert len(rows) == 1
    eggs = rows[0]
    assert eggs.ingredient_name == "Eggs"
    assert eggs.total_quantity == 100.0
    assert eggs.unit == "ct"
    assert "pantry-supplement:" in eggs.source_meals


def test_supplement_merges_into_week_event_quantity() -> None:
    """When auto_merge is on, the supplement lands on the linked week
    as event_quantity — sums alongside the recurring pantry row."""
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session)
        week = create_or_get_week(
            session,
            user_id=_uid,
            household_id=_uid,
            week_start=date(2026, 4, 20),
            notes="event week",
        )
        event.linked_week_id = week.id
        session.flush()

        # Recurring pantry: 60 eggs land on the week as user_added.
        from app.services.pantry import apply_pantry_recurrings

        apply_pantry_recurrings(session, week=week, household_id=_uid)

        # Event supplement: 100 extra for the event.
        add_supplement(
            session,
            event=event,
            pantry_item_id=pantry.id,
            quantity=100.0,
            unit="ct",
            household_id=_uid,
        )
        regenerate_event_grocery(session, _uid, event)
        apply_auto_merge_policy(session, event=event, user_id=_uid, household_id=_uid)
        session.flush()

        eggs_rows = list(
            session.scalars(
                select(GroceryItem).where(
                    GroceryItem.week_id == week.id,
                    GroceryItem.normalized_name == "eggs",
                )
            ).all()
        )

    assert len(eggs_rows) == 1
    eggs = eggs_rows[0]
    # Recurring pantry: 60 eggs in total_quantity (user_added).
    assert eggs.total_quantity == 60.0
    # Event supplement: 100 eggs in event_quantity.
    assert eggs.event_quantity == 100.0


def test_duplicate_supplement_for_same_pantry_item_rejected() -> None:
    """At most one supplement per pantry item per event — the user
    edits an existing one rather than stacking duplicates."""
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session)
        add_supplement(
            session,
            event=event,
            pantry_item_id=pantry.id,
            quantity=50.0,
            household_id=_uid,
        )
        try:
            add_supplement(
                session,
                event=event,
                pantry_item_id=pantry.id,
                quantity=25.0,
                household_id=_uid,
            )
            raise AssertionError("expected ValueError on duplicate")
        except ValueError as exc:
            assert "already exists" in str(exc).lower()


def test_supplement_update_and_delete() -> None:
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session)
        sup = add_supplement(
            session,
            event=event,
            pantry_item_id=pantry.id,
            quantity=50.0,
            unit="ct",
            household_id=_uid,
        )
        sup_id = sup.id
        update_supplement(session, supplement=sup, fields={"quantity": 80.0, "notes": "more"})
        refreshed = session.get(EventPantrySupplement, sup_id)
        assert refreshed is not None
        assert refreshed.quantity == 80.0
        assert refreshed.notes == "more"

        delete_supplement(session, supplement=refreshed)
        gone = session.get(EventPantrySupplement, sup_id)
    assert gone is None


def test_supplement_quantity_must_be_positive() -> None:
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session)
        try:
            add_supplement(
                session,
                event=event,
                pantry_item_id=pantry.id,
                quantity=0,
                household_id=_uid,
            )
            raise AssertionError("expected ValueError for non-positive quantity")
        except ValueError:
            pass


def test_supplement_visible_in_event_payload() -> None:
    """The presenter must surface supplements alongside grocery_items."""
    with session_scope() as session:
        event, pantry = _seed_event_with_pantry_item(session, event_name="Birthday Bash")
        add_supplement(
            session,
            event=event,
            pantry_item_id=pantry.id,
            quantity=24.0,
            unit="ct",
            household_id=_uid,
        )
        session.commit()
        from app.services.event_presenters import event_payload

        fresh = get_event(session, _uid, event.id)
        payload = event_payload(fresh)

    sups = payload["pantry_supplements"]
    assert len(sups) == 1
    assert sups[0]["pantry_item_name"] == "Eggs"
    assert sups[0]["quantity"] == 24.0
