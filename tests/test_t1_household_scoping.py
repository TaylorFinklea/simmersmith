"""T1 — finish the M21 household migration.

Each test maps to a confirmed finding from the 2026-06-13 ultracode bug-bash
(.docs/ai/phases/bugbash-2026-06-13-report.md): household-scoped uniqueness
(#8 staples, #23 weeks) and the cluster of reads/writes that were still keyed
on user_id instead of household_id (#14, #16, #21, #24, #34, #35, #49).
"""
from __future__ import annotations

import asyncio
from datetime import date, datetime
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.db import session_scope
from app.models._base import new_id, utcnow
from app.models.household import HouseholdMember
from app.models.profile import PreferenceSignal, Staple
from app.models.push import PushDevice
from app.models.recipe import Recipe
from app.models.user import User
from app.models.week import FeedbackEntry, Week, WeekMeal
from app.schemas import StaplePayload
from app.services.households import create_solo_household


# ── helpers ─────────────────────────────────────────────────────────


def _user(session, prefix: str) -> str:
    uid = new_id()
    session.add(User(id=uid, email=f"{prefix}-{uid[:8]}@test.com", created_at=utcnow()))
    session.flush()
    return uid


def _solo(session, prefix: str) -> tuple[str, str]:
    """(user_id, household_id) for a fresh solo household."""
    uid = _user(session, prefix)
    return uid, create_solo_household(session, uid)


def _two_member_household(session) -> tuple[str, str, str]:
    """(household_id, owner_id, member_id) — member has no prior household."""
    owner, hh = _solo(session, "owner")
    member = _user(session, "member")
    session.add(
        HouseholdMember(id=new_id(), household_id=hh, user_id=member, role="member", joined_at=utcnow())
    )
    session.flush()
    return hh, owner, member


def _add_week(session, *, user_id: str, household_id: str, week_start: date, status: str = "staging") -> Week:
    week = Week(
        id=new_id(),
        user_id=user_id,
        household_id=household_id,
        week_start=week_start,
        week_end=week_start,
        status=status,
    )
    session.add(week)
    session.flush()
    return week


# ── #23 — weeks UNIQUE(household_id, week_start) ─────────────────────


def test_two_households_can_plan_the_same_week_start() -> None:
    from app.services.weeks import create_or_get_week

    with session_scope() as session:
        a, hh_a = _solo(session, "a")
        b, hh_b = _solo(session, "b")
        wk = date(2026, 7, 6)
        w_a = create_or_get_week(session, user_id=a, household_id=hh_a, week_start=wk)
        w_b = create_or_get_week(session, user_id=b, household_id=hh_b, week_start=wk)
        session.flush()
        assert w_a.id != w_b.id


def test_household_members_converge_on_one_week() -> None:
    from app.services.weeks import create_or_get_week

    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        wk = date(2026, 7, 13)
        w1 = create_or_get_week(session, user_id=owner, household_id=hh, week_start=wk)
        session.flush()
        w2 = create_or_get_week(session, user_id=member, household_id=hh, week_start=wk)
        assert w1.id == w2.id


def test_duplicate_household_week_rejected_at_db() -> None:
    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        wk = date(2026, 7, 20)
        _add_week(session, user_id=owner, household_id=hh, week_start=wk)
        session.add(
            Week(id=new_id(), user_id=member, household_id=hh, week_start=wk, week_end=wk, status="staging")
        )
        with pytest.raises(IntegrityError):
            session.flush()
        session.rollback()


# ── #8 — staples UNIQUE(household_id, normalized_name) ───────────────


def test_duplicate_household_staple_rejected_at_db() -> None:
    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        session.add(Staple(id=new_id(), user_id=owner, household_id=hh, staple_name="Milk", normalized_name="milk"))
        session.flush()
        session.add(Staple(id=new_id(), user_id=member, household_id=hh, staple_name="Milk", normalized_name="milk"))
        with pytest.raises(IntegrityError):
            session.flush()
        session.rollback()


def test_two_households_can_have_same_staple() -> None:
    with session_scope() as session:
        a, hh_a = _solo(session, "a")
        b, hh_b = _solo(session, "b")
        session.add(Staple(id=new_id(), user_id=a, household_id=hh_a, staple_name="Milk", normalized_name="milk"))
        session.add(Staple(id=new_id(), user_id=b, household_id=hh_b, staple_name="Milk", normalized_name="milk"))
        session.flush()  # different households — allowed


# ── #14 — update_profile must not wipe a housemate's staples ─────────


def test_update_profile_preserves_housemate_staples() -> None:
    from app.services.profile import update_profile

    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        session.add(Staple(id=new_id(), user_id=member, household_id=hh, staple_name="Eggs", normalized_name="eggs"))
        session.flush()

        update_profile(
            session,
            owner,
            hh,
            settings={},
            staples=[StaplePayload(staple_name="Flour", normalized_name="flour")],
        )

        names = {
            s.normalized_name
            for s in session.scalars(select(Staple).where(Staple.household_id == hh)).all()
        }
        assert "eggs" in names  # housemate row survived (bug #14 deleted it)
        assert "flour" in names


# ── #49 — pantry rename respects household dedup ─────────────────────


def test_pantry_rename_collision_rejected() -> None:
    from app.services.pantry import add_pantry_item, update_pantry_item

    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        add_pantry_item(session, user_id=owner, household_id=hh, name="Whole Milk")
        b_item = add_pantry_item(session, user_id=member, household_id=hh, name="Skim Milk")
        with pytest.raises(ValueError):
            update_pantry_item(session, item=b_item, fields={"staple_name": "Whole Milk"})
        session.rollback()


# ── #16 — feedback preference rebuild is household-scoped ────────────


def test_feedback_signals_scoped_to_household() -> None:
    from app.services.feedback import rebuild_feedback_preference_signals

    with session_scope() as session:
        a, hh_a = _solo(session, "a")
        b, hh_b = _solo(session, "b")
        wk = date(2026, 8, 3)
        _add_week(session, user_id=a, household_id=hh_a, week_start=wk)
        w_b = _add_week(session, user_id=b, household_id=hh_b, week_start=wk)
        # Household B dislikes cilantro.
        session.add(
            FeedbackEntry(
                id=new_id(),
                week_id=w_b.id,
                target_type="ingredient",
                target_name="Cilantro",
                normalized_name="cilantro",
                sentiment=-1,
                active=True,
            )
        )
        session.flush()

        rebuild_feedback_preference_signals(session, a, hh_a)
        a_signals = session.scalars(select(PreferenceSignal).where(PreferenceSignal.user_id == a)).all()
        assert all(s.normalized_name != "cilantro" for s in a_signals)  # no cross-household leak (bug #16)

        rebuild_feedback_preference_signals(session, b, hh_b)
        b_signals = session.scalars(
            select(PreferenceSignal).where(
                PreferenceSignal.user_id == b, PreferenceSignal.source == "feedback"
            )
        ).all()
        assert any(s.normalized_name == "cilantro" for s in b_signals)


# ── #34 / #35 — week planner uses the household pantry + recent meals ─


def test_planning_context_uses_household_pantry_and_recent_meals() -> None:
    from app.services.week_planner import gather_planning_context

    with session_scope() as session:
        u, hh = _solo(session, "planner")
        session.add(
            Staple(id=new_id(), user_id=u, household_id=hh, staple_name="Olive Oil", normalized_name="olive oil", is_active=True)
        )
        wk = date(2026, 5, 4)
        week = _add_week(session, user_id=u, household_id=hh, week_start=wk, status="approved")
        session.add(
            WeekMeal(id=new_id(), week_id=week.id, day_name="Monday", meal_date=wk, slot="dinner", recipe_name="Lentil Soup", source="ai")
        )
        session.flush()

        ctx = gather_planning_context(session, u, household_id=hh)
        assert "olive oil" in ctx.staples  # bug #34: was empty (queried by user_id)
        assert "Lentil Soup" in ctx.recent_meals  # bug #35: was empty (queried by user_id)


# ── #24 — push scheduler notifies non-creator household members ──────


def _now_fn(target_dt: datetime):
    def _fn(tz_name: str) -> datetime:
        return target_dt
    return _fn


def test_scheduler_notifies_non_creator_member() -> None:
    from app.config import get_settings
    from app.models import ProfileSetting
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        hh, owner, member = _two_member_household(session)
        # Member B has the push device + toggles; the WEEK belongs to owner A.
        session.add(
            PushDevice(
                id=new_id(),
                user_id=member,
                device_token="memberpush" + "d" * 50,
                platform="ios",
                apns_environment="sandbox",
                bundle_id="app.simmersmith.ios",
                last_seen_at=utcnow(),
                created_at=utcnow(),
                updated_at=utcnow(),
            )
        )
        for key, val in (
            ("push_tonights_meal", "1"),
            ("timezone", "America/Chicago"),
            ("push_tonights_meal_time", "17:00"),
        ):
            session.merge(ProfileSetting(user_id=member, key=key, value=val, updated_at=utcnow()))
        session.flush()

        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 1, 17, 0, 0, tzinfo=tz)  # Monday 17:00
        today_local = target_dt.date()
        week = _add_week(session, user_id=owner, household_id=hh, week_start=today_local)
        session.add(
            WeekMeal(id=new_id(), week_id=week.id, day_name="Monday", meal_date=today_local, slot="dinner", recipe_name="Roast Chicken", source="ai")
        )
        session.flush()

        _sent_today.pop(("tonights_meal", member, today_local.isoformat()), None)

        mock_result = MagicMock(is_successful=True)
        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)
        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            asyncio.run(_process_tonights_meal(session, get_settings(), member, _now_fn(target_dt)))

        # Without household scoping the query (Week.user_id == member) finds
        # nothing and no push is sent; with the fix the member is notified.
        assert mock_client.send_notification.call_count == 1


# ── #21 — MCP assistant resolves the attached recipe by household ────


def test_mcp_assistant_resolves_attached_recipe_by_household(monkeypatch) -> None:
    import app.mcp.assistant as mcp_assistant
    from app.mcp._helpers import _current_user_id_var
    from app.services.assistant_threads import create_thread

    captured: dict[str, Any] = {}

    class _Stop(Exception):
        pass

    def _fake_run(**kwargs: Any):
        captured["attached_recipe"] = kwargs.get("attached_recipe")
        raise _Stop("captured")

    monkeypatch.setattr(mcp_assistant, "run_assistant_turn", _fake_run)

    with session_scope() as session:
        u, hh = _solo(session, "mcp")
        rid = new_id()
        session.add(Recipe(id=rid, user_id=u, household_id=hh, name="Test Recipe"))
        thread = create_thread(session, u, title="t")
        thread_id = thread.id
        session.flush()

    token = _current_user_id_var.set(u)
    try:
        with pytest.raises(ValueError):
            mcp_assistant.assistant_respond(thread_id=thread_id, text="hi", attached_recipe_id=rid)
    finally:
        _current_user_id_var.reset(token)

    # Resolved via household_id (not user_id, which would have returned None).
    assert captured["attached_recipe"] is not None
    assert captured["attached_recipe"].name == "Test Recipe"
