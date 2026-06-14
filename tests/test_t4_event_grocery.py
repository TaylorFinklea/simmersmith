"""T4 — event↔week grocery merge lifecycle (2026-06-13 bug bash).

#9  deleting a merged event must reconcile the week's grocery (no zombie rows),
#10 re-dating an auto-merged event must re-point the merge to the new week,
#11 editing a manually-merged event must NOT silently drop the merge,
#37 renaming an event after merge must still unmerge cleanly (stable marker),
#38 AI menu regen must not collide sort_order with preserved manual meals.
"""
from __future__ import annotations

from datetime import date, timedelta

from sqlalchemy import select

from app.db import session_scope
from app.models._base import new_id
from app.models.event import Event, EventMeal, EventMealIngredient
from app.models.user import User
from app.models.week import GroceryItem, Week
from app.services.event_grocery import (
    apply_auto_merge_policy,
    merge_event_into_week,
    regenerate_event_grocery,
    unmerge_event_from_week,
)
from app.services.events import delete_event
from app.services.households import create_solo_household


def _user(session) -> str:
    uid = new_id()
    session.add(User(id=uid, email=f"t4-{uid[:8]}@test.com"))
    session.flush()
    return uid


def _week(session, *, user_id: str, household_id: str, start: date) -> Week:
    week = Week(
        id=new_id(), user_id=user_id, household_id=household_id,
        week_start=start, week_end=start + timedelta(days=6), status="staging",
    )
    session.add(week)
    session.flush()
    return week


def _event_with_grocery(session, *, user_id, household_id, event_date, auto_merge=True, name="Party") -> Event:
    """An event with one meal + inline ingredient, grocery rows already built."""
    event = Event(
        id=new_id(), user_id=user_id, household_id=household_id, name=name,
        event_date=event_date, auto_merge_grocery=auto_merge,
    )
    session.add(event)
    session.flush()
    meal = EventMeal(event_id=event.id, recipe_name="Cake", ai_generated=False, sort_order=0)
    session.add(meal)
    session.flush()
    session.add(EventMealIngredient(
        id=new_id(), event_meal_id=meal.id, ingredient_name="Confetti Cake Mix",
        normalized_name="confetti cake mix", quantity=2.0, unit="box",
    ))
    session.flush()
    session.expire(event, ["meals", "grocery_items"])
    regenerate_event_grocery(session, user_id, household_id, event)
    return event


def _event_rows_on_week(session, week_id: str) -> list[GroceryItem]:
    rows = session.scalars(select(GroceryItem).where(GroceryItem.week_id == week_id)).all()
    return [r for r in rows if (r.source_meals or "").startswith("event:")]


# ── #9 — deleting a merged event reconciles the week ─────────────────


def test_deleting_merged_event_reconciles_week_grocery() -> None:
    with session_scope() as session:
        uid = _user(session)
        hh = create_solo_household(session, uid)
        week = _week(session, user_id=uid, household_id=hh, start=date(2026, 10, 5))
        event = _event_with_grocery(session, user_id=uid, household_id=hh, event_date=date(2026, 10, 6))

        merge_event_into_week(session, user_id=uid, event=event, week=week)
        session.flush()
        assert _event_rows_on_week(session, week.id)  # merge created an event-only row

        delete_event(session, event)
        session.flush()
        assert not _event_rows_on_week(session, week.id)  # bug #9: zombie row left behind


# ── #37 — renaming after merge still unmerges cleanly ────────────────


def test_rename_after_merge_unmerges_cleanly() -> None:
    with session_scope() as session:
        uid = _user(session)
        hh = create_solo_household(session, uid)
        week = _week(session, user_id=uid, household_id=hh, start=date(2026, 10, 5))
        event = _event_with_grocery(session, user_id=uid, household_id=hh, event_date=date(2026, 10, 6))

        merge_event_into_week(session, user_id=uid, event=event, week=week)
        session.flush()
        event.name = "Birthday"  # renamed between merge and unmerge
        session.flush()

        unmerge_event_from_week(session, event=event, week=week)
        session.flush()
        # bug #37: the by-name marker no longer matched -> row was stranded.
        assert not _event_rows_on_week(session, week.id)


# ── #10 — re-dating an auto-merged event re-points to the new week ───


def test_redating_event_repoints_merge() -> None:
    with session_scope() as session:
        uid = _user(session)
        hh = create_solo_household(session, uid)
        week_j = _week(session, user_id=uid, household_id=hh, start=date(2026, 10, 5))   # 10-05..10-11
        week_k = _week(session, user_id=uid, household_id=hh, start=date(2026, 10, 12))  # 10-12..10-18
        event = _event_with_grocery(session, user_id=uid, household_id=hh, event_date=date(2026, 10, 6))

        apply_auto_merge_policy(session, event=event, user_id=uid, household_id=hh)
        session.flush()
        assert _event_rows_on_week(session, week_j.id)
        assert not _event_rows_on_week(session, week_k.id)
        assert event.linked_week_id == week_j.id

        event.event_date = date(2026, 10, 13)  # moved into week K
        session.flush()
        apply_auto_merge_policy(session, event=event, user_id=uid, household_id=hh)
        session.flush()
        # bug #10: grocery stayed on J; should move to K.
        assert not _event_rows_on_week(session, week_j.id)
        assert _event_rows_on_week(session, week_k.id)
        assert event.linked_week_id == week_k.id


# ── #11 — a manual merge survives a later edit (regenerate) ──────────


def test_manual_merge_survives_regenerate() -> None:
    with session_scope() as session:
        uid = _user(session)
        hh = create_solo_household(session, uid)
        week = _week(session, user_id=uid, household_id=hh, start=date(2026, 10, 5))
        # Potluck: auto-merge OFF, then the user manually merges into the week.
        event = _event_with_grocery(session, user_id=uid, household_id=hh, event_date=date(2026, 10, 6), auto_merge=False)

        merge_event_into_week(session, user_id=uid, event=event, week=week)
        event.manually_merged = True  # what POST /grocery/merge sets
        session.flush()
        assert _event_rows_on_week(session, week.id)

        # Simulate an edit (what _refresh_event_after_* does): rebuild + reconcile.
        regenerate_event_grocery(session, uid, hh, event)
        apply_auto_merge_policy(session, event=event, user_id=uid, household_id=hh)
        session.flush()
        # bug #11: auto=False + linked was read as "unmerge" and wiped it.
        assert _event_rows_on_week(session, week.id)
        assert event.linked_week_id == week.id


# ── #38 — AI menu regen doesn't collide sort_order with manual meals ─


def test_event_ai_regen_sort_order_no_collision() -> None:
    from app.services.events import replace_event_meals

    with session_scope() as session:
        uid = _user(session)
        hh = create_solo_household(session, uid)
        event = Event(id=new_id(), user_id=uid, household_id=hh, name="Dinner", auto_merge_grocery=False)
        session.add(event)
        session.flush()
        session.add(EventMeal(event_id=event.id, recipe_name="Salad", ai_generated=False, sort_order=0))
        session.flush()
        session.expire(event, ["meals"])

        # event_ai supplies 0-based sort_order on each AI entry.
        ai_entries = [
            {"recipe_name": "Turkey", "ai_generated": True, "sort_order": 0},
            {"recipe_name": "Pie", "ai_generated": True, "sort_order": 1},
        ]
        replace_event_meals(session, event, ai_entries, preserve_manual=True)
        session.flush()
        session.expire(event, ["meals"])

        meals = sorted(event.meals, key=lambda m: m.sort_order)
        orders = [m.sort_order for m in meals]
        assert len(set(orders)) == len(orders)  # bug #38: Salad=0 and Turkey=0 collided
        assert meals[0].recipe_name == "Salad"  # manual meal stays first
