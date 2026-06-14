"""IDOR lane — cross-user/cross-household writes via client-supplied ids.

Each test maps to a confirmed finding from the 2026-06-13 ultracode bug-bash
(.docs/ai/phases/bugbash-2026-06-13-report.md): preference upsert overwriting
another user's signal by preference_id (#13) and feedback upsert hijacking an
arbitrary feedback row by feedback_id and reassigning it to the caller's week
(#17).
"""
from __future__ import annotations

from datetime import date

from sqlalchemy import select

from app.db import session_scope
from app.models._base import new_id, utcnow
from app.models.profile import PreferenceSignal
from app.models.user import User
from app.models.week import FeedbackEntry, Week
from app.schemas import FeedbackEntryPayload, PreferenceSignalPayload
from app.services.feedback import upsert_feedback_entries
from app.services.households import create_solo_household
from app.services.preferences import upsert_preference_signals


def _user(session, prefix: str) -> str:
    uid = new_id()
    session.add(User(id=uid, email=f"{prefix}-{uid[:8]}@test.com", created_at=utcnow()))
    session.flush()
    return uid


def _solo(session, prefix: str) -> tuple[str, str]:
    uid = _user(session, prefix)
    return uid, create_solo_household(session, uid)


def _add_week(session, *, user_id: str, household_id: str, week_start: date) -> Week:
    week = Week(
        id=new_id(),
        user_id=user_id,
        household_id=household_id,
        week_start=week_start,
        week_end=week_start,
        status="staging",
    )
    session.add(week)
    session.flush()
    return week


# ── #13 — preference upsert must not overwrite another user's signal ──


def test_preference_upsert_cannot_overwrite_other_users_signal() -> None:
    with session_scope() as session:
        a, _ = _solo(session, "a")
        b, _ = _solo(session, "b")
        # Victim B has an allergy signal that meal-safety scoring relies on.
        victim = PreferenceSignal(
            id=new_id(),
            user_id=b,
            signal_type="ingredient",
            name="Peanut",
            normalized_name="peanut",
            score=-5,
            weight=5,
            active=True,
        )
        session.add(victim)
        session.flush()
        victim_id = victim.id

        # Attacker A submits the victim's preference_id, trying to flip the
        # signal off and rename it.
        stored = upsert_preference_signals(
            session,
            a,
            [
                PreferenceSignalPayload(
                    preference_id=victim_id,
                    signal_type="ingredient",
                    name="Harmless",
                    normalized_name="harmless",
                    score=5,
                    active=False,
                )
            ],
        )

        # The victim's row is untouched.
        refreshed = session.get(PreferenceSignal, victim_id)
        assert refreshed.user_id == b
        assert refreshed.name == "Peanut"
        assert refreshed.score == -5
        assert refreshed.active is True

        # A new row was created for the attacker instead of hijacking B's.
        assert len(stored) == 1
        assert stored[0].id != victim_id
        assert stored[0].user_id == a


def test_preference_upsert_still_updates_own_signal() -> None:
    with session_scope() as session:
        a, _ = _solo(session, "a")
        own = PreferenceSignal(
            id=new_id(),
            user_id=a,
            signal_type="meal",
            name="Tacos",
            normalized_name="tacos",
            score=2,
            weight=3,
            active=True,
        )
        session.add(own)
        session.flush()
        own_id = own.id

        stored = upsert_preference_signals(
            session,
            a,
            [
                PreferenceSignalPayload(
                    preference_id=own_id,
                    signal_type="meal",
                    name="Tacos",
                    normalized_name="tacos",
                    score=5,
                    active=True,
                )
            ],
        )

        assert len(stored) == 1
        assert stored[0].id == own_id  # updated in place, no new row
        refreshed = session.get(PreferenceSignal, own_id)
        assert refreshed.score == 5


# ── #17 — feedback upsert must not hijack another week's entry ────────


def test_feedback_upsert_cannot_hijack_other_households_entry() -> None:
    with session_scope() as session:
        a, hh_a = _solo(session, "a")
        b, hh_b = _solo(session, "b")
        week_a = _add_week(session, user_id=a, household_id=hh_a, week_start=date(2026, 9, 7))
        week_b = _add_week(session, user_id=b, household_id=hh_b, week_start=date(2026, 9, 7))

        victim = FeedbackEntry(
            id=new_id(),
            week_id=week_b.id,
            target_type="ingredient",
            target_name="Cilantro",
            normalized_name="cilantro",
            sentiment=-2,
            active=True,
        )
        session.add(victim)
        session.flush()
        victim_id = victim.id

        # Attacker A submits the victim's feedback_id against their own week.
        stored = upsert_feedback_entries(
            session,
            a,
            week_a,
            [
                FeedbackEntryPayload(
                    feedback_id=victim_id,
                    target_type="ingredient",
                    target_name="Hijacked",
                    normalized_name="hijacked",
                    sentiment=2,
                    active=True,
                )
            ],
        )

        # The victim's row stays on B's week with its original content.
        refreshed = session.get(FeedbackEntry, victim_id)
        assert refreshed.week_id == week_b.id
        assert refreshed.target_name == "Cilantro"
        assert refreshed.sentiment == -2

        # A new row was created on the attacker's week instead.
        assert len(stored) == 1
        assert stored[0].id != victim_id
        assert stored[0].week_id == week_a.id


def test_feedback_upsert_still_updates_own_weeks_entry() -> None:
    with session_scope() as session:
        a, hh_a = _solo(session, "a")
        week_a = _add_week(session, user_id=a, household_id=hh_a, week_start=date(2026, 9, 14))

        existing = FeedbackEntry(
            id=new_id(),
            week_id=week_a.id,
            target_type="meal",
            target_name="Chili",
            normalized_name="chili",
            sentiment=1,
            active=True,
        )
        session.add(existing)
        session.flush()
        existing_id = existing.id

        stored = upsert_feedback_entries(
            session,
            a,
            week_a,
            [
                FeedbackEntryPayload(
                    feedback_id=existing_id,
                    target_type="meal",
                    target_name="Chili",
                    normalized_name="chili",
                    sentiment=2,
                    active=True,
                )
            ],
        )

        assert len(stored) == 1
        assert stored[0].id == existing_id  # updated in place, no new row
        refreshed = session.get(FeedbackEntry, existing_id)
        assert refreshed.sentiment == 2

        # Only the one entry exists on the week.
        rows = session.scalars(
            select(FeedbackEntry).where(FeedbackEntry.week_id == week_a.id)
        ).all()
        assert len(rows) == 1
