"""Pantry lane — 2026-06-13 bug bash batch.

#30 Recurring pantry cadence gated on wall-clock apply time instead of the
    week being planned, so planning several future weeks in one sitting
    dropped biweekly/monthly recurring items on every week after the first
    (app/services/pantry.py:_is_due / apply_pantry_recurrings).

These tests exercise the service layer directly with the shared conftest
fixtures (db_session, current_user). The fix reinterprets `last_applied_at`
as the *week_start* the item was last folded into (no schema migration) and
measures the cadence gap against `week.week_start` rather than wall-clock now.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from app.services.pantry import add_pantry_item, apply_pantry_recurrings


_PREFIX = "pantry:recurring:"


def _add_recurring(db_session, current_user, *, cadence: str, name: str):
    return add_pantry_item(
        db_session,
        user_id=current_user.id,
        household_id=current_user.household_id,
        name=name,
        recurring_quantity=1.0,
        recurring_unit="each",
        recurring_cadence=cadence,
    )


def _make_week(db_session, current_user, week_start: date):
    from app.services.weeks import create_or_get_week

    week = create_or_get_week(
        db_session,
        user_id=current_user.id,
        household_id=current_user.household_id,
        week_start=week_start,
    )
    db_session.flush()
    return week


def _marker_quantities(rows, item_id: str):
    marker = f"{_PREFIX}{item_id}"
    return [r for r in rows if r.source_meals == marker]


# ── #30 — biweekly restock lands on every batch-planned week ──────────────────


def test_biweekly_lands_on_each_week_when_planning_ahead_in_one_sitting(
    db_session, current_user
) -> None:
    """Plan three consecutive weeks in one sitting (same wall-clock `now`).
    A biweekly item must land on the weeks two cadence-widths apart — pre-fix
    the (now - last_applied_at) gap was ~0 for every apply, so weeks 2/3 were
    silently dropped."""
    item = _add_recurring(db_session, current_user, cadence="biweekly", name="Olive Oil")

    base = date(2026, 7, 6)  # a Monday
    now = datetime(2026, 7, 1, 12, 0, tzinfo=timezone.utc)

    # week 0 — first apply, always due.
    w0 = _make_week(db_session, current_user, base)
    landed0 = apply_pantry_recurrings(
        db_session, week=w0, household_id=current_user.household_id, now=now
    )
    assert _marker_quantities(landed0, item.id), "biweekly should fire on the first week"

    # week 1 — 7 days later. biweekly (min 13 days of week_start gap) → NOT due.
    w1 = _make_week(db_session, current_user, base + timedelta(days=7))
    landed1 = apply_pantry_recurrings(
        db_session, week=w1, household_id=current_user.household_id, now=now
    )
    assert not _marker_quantities(landed1, item.id), "biweekly should skip the 7-day-out week"

    # week 2 — 14 days out. week_start gap (14 >= 13) → due again, even though
    # wall-clock `now` has not moved at all.
    w2 = _make_week(db_session, current_user, base + timedelta(days=14))
    landed2 = apply_pantry_recurrings(
        db_session, week=w2, household_id=current_user.household_id, now=now
    )
    assert _marker_quantities(landed2, item.id), "biweekly should fire on the 14-day-out week"


def test_monthly_lands_four_weeks_out_in_one_sitting(db_session, current_user) -> None:
    """Monthly (min 27 days) must skip the 14-day-out week and land 28 days out,
    with wall-clock `now` frozen across all applies."""
    item = _add_recurring(db_session, current_user, cadence="monthly", name="Dish Soap")

    base = date(2026, 8, 3)
    now = datetime(2026, 8, 1, 9, 0, tzinfo=timezone.utc)

    w0 = _make_week(db_session, current_user, base)
    landed0 = apply_pantry_recurrings(
        db_session, week=w0, household_id=current_user.household_id, now=now
    )
    assert _marker_quantities(landed0, item.id)

    w_mid = _make_week(db_session, current_user, base + timedelta(days=14))
    landed_mid = apply_pantry_recurrings(
        db_session, week=w_mid, household_id=current_user.household_id, now=now
    )
    assert not _marker_quantities(landed_mid, item.id), "monthly should skip the 14-day-out week"

    w_far = _make_week(db_session, current_user, base + timedelta(days=28))
    landed_far = apply_pantry_recurrings(
        db_session, week=w_far, household_id=current_user.household_id, now=now
    )
    assert _marker_quantities(landed_far, item.id), "monthly should fire 28 days out"


def test_weekly_lands_on_consecutive_weeks(db_session, current_user) -> None:
    """`weekly` (min 0) is always due regardless of gap."""
    item = _add_recurring(db_session, current_user, cadence="weekly", name="Milk")

    base = date(2026, 9, 7)
    now = datetime(2026, 9, 1, tzinfo=timezone.utc)

    for offset in (0, 7, 14):
        week = _make_week(db_session, current_user, base + timedelta(days=offset))
        landed = apply_pantry_recurrings(
            db_session, week=week, household_id=current_user.household_id, now=now
        )
        assert _marker_quantities(landed, item.id), f"weekly should fire at +{offset}d"


def test_applied_marker_stores_week_start_not_wallclock(db_session, current_user) -> None:
    """After apply, `last_applied_at` reflects the planned week_start (midnight
    UTC), not the wall-clock `now` passed in — the baseline the cadence gap is
    measured against."""
    item = _add_recurring(db_session, current_user, cadence="biweekly", name="Coffee")

    week_start = date(2026, 10, 5)
    now = datetime(2026, 10, 1, 16, 30, tzinfo=timezone.utc)
    week = _make_week(db_session, current_user, week_start)

    apply_pantry_recurrings(
        db_session, week=week, household_id=current_user.household_id, now=now
    )
    db_session.refresh(item)

    assert item.last_applied_at is not None
    assert item.last_applied_at.date() == week_start


def test_replanning_same_week_after_real_time_does_not_misfire(db_session, current_user) -> None:
    """Re-running apply on the SAME week with a much later wall-clock `now`
    stays idempotent and does not insert a second biweekly marker row — the
    gate keys on week_start, not elapsed real time. (The cadence gap for the
    same week is 0, so the second apply no longer re-fires off elapsed time.)"""
    from sqlalchemy import select

    from app.models import GroceryItem

    item = _add_recurring(db_session, current_user, cadence="biweekly", name="Butter")

    week_start = date(2026, 11, 2)
    week = _make_week(db_session, current_user, week_start)

    apply_pantry_recurrings(
        db_session,
        week=week,
        household_id=current_user.household_id,
        now=datetime(2026, 10, 28, tzinfo=timezone.utc),
    )
    apply_pantry_recurrings(
        db_session,
        week=week,
        household_id=current_user.household_id,
        now=datetime(2026, 12, 1, tzinfo=timezone.utc),  # weeks later in wall-clock
    )

    marker = f"{_PREFIX}{item.id}"
    persisted = db_session.scalars(
        select(GroceryItem).where(
            GroceryItem.week_id == week.id,
            GroceryItem.source_meals == marker,
        )
    ).all()
    assert len(persisted) == 1, "re-applying the same week must not insert a duplicate marker row"
