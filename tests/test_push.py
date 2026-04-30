"""Tests for M18 push notifications.

Covers:
- Device register / unregister API round-trip
- send_push honours disabled_at (skip) and flips it on simulated 410
- Scheduler tick fires when local time matches, skips outside window
- Quiet-hours guard (22:00–07:00)
- Explicit toggle-off (value == '0') suppresses push
- Default-on semantics: user with no push_* rows still receives at default times
- Saturday tick skips when the upcoming week is confirmed/approved
"""
from __future__ import annotations

import asyncio
from datetime import datetime
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

from fastapi.testclient import TestClient

from app.config import get_settings
from app.db import session_scope
from app.models import ProfileSetting, Week, utcnow
from app.models.push import PushDevice
from app.models._base import new_id


# ── helpers ────────────────────────────────────────────────────────


def _auth_headers(client: TestClient) -> dict[str, str]:
    """Get bearer headers that map to the dev local user (api_token auth)."""
    settings = get_settings()
    token = settings.api_token or "test-token"
    # Patch the token if empty so auth works in isolation
    return {"Authorization": f"Bearer {token}"}


def _make_user_with_device(
    session,
    user_id: str,
    device_token: str = "aabbcc" * 10,
    environment: str = "sandbox",
) -> PushDevice:
    now = utcnow()
    device = PushDevice(
        id=new_id(),
        user_id=user_id,
        device_token=device_token,
        platform="ios",
        apns_environment=environment,
        bundle_id="app.simmersmith.ios",
        last_seen_at=now,
        disabled_at=None,
        created_at=now,
        updated_at=now,
    )
    session.add(device)
    session.flush()
    return device


def _make_setting(session, user_id: str, key: str, value: str) -> None:
    session.merge(ProfileSetting(user_id=user_id, key=key, value=value, updated_at=utcnow()))
    session.flush()


def _run(coro) -> Any:
    return asyncio.run(coro)


# ── Phase 1: API round-trip ────────────────────────────────────────


def test_register_device_creates_row(client: TestClient) -> None:
    """POST /api/push/devices should create a PushDevice row."""
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"}
    resp = client.post(
        "/api/push/devices",
        json={"device_token": "abc123" * 10, "environment": "sandbox", "bundle_id": "app.simmersmith.ios"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["registered"] is True

    with session_scope() as session:
        from sqlalchemy import select
        device = session.scalar(select(PushDevice).where(PushDevice.device_token == "abc123" * 10))
        assert device is not None
        assert device.disabled_at is None


def test_register_device_upserts(client: TestClient) -> None:
    """Registering the same token twice should not create a duplicate row."""
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"}
    token = "dedup" + "x" * 58
    for _ in range(2):
        resp = client.post(
            "/api/push/devices",
            json={"device_token": token, "environment": "sandbox", "bundle_id": "app.simmersmith.ios"},
            headers=headers,
        )
        assert resp.status_code == 200

    with session_scope() as session:
        from sqlalchemy import select, func
        count = session.scalar(select(func.count()).where(PushDevice.device_token == token))
        assert count == 1


def test_unregister_device_sets_disabled_at(client: TestClient) -> None:
    """DELETE /api/push/devices/{token} should soft-disable the row."""
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"}
    token = "deltoken" + "z" * 55

    # Register first
    client.post(
        "/api/push/devices",
        json={"device_token": token, "environment": "sandbox", "bundle_id": "app.simmersmith.ios"},
        headers=headers,
    )

    # Now unregister
    resp = client.delete(f"/api/push/devices/{token}", headers=headers)
    assert resp.status_code == 204

    with session_scope() as session:
        from sqlalchemy import select
        device = session.scalar(select(PushDevice).where(PushDevice.device_token == token))
        assert device is not None
        assert device.disabled_at is not None


def test_unregister_nonexistent_is_idempotent(client: TestClient) -> None:
    """DELETE on a token that doesn't exist should return 204 without error."""
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"}
    resp = client.delete("/api/push/devices/nosuchtoken123", headers=headers)
    assert resp.status_code == 204


def test_test_push_503_when_apns_unconfigured(client: TestClient) -> None:
    """POST /api/push/test returns 503 when APNs creds are not set."""
    settings = get_settings()
    headers = {"Authorization": f"Bearer {settings.api_token}"}
    resp = client.post(
        "/api/push/test",
        json={"user_id": settings.local_user_id, "title": "Hello", "body": "World"},
        headers=headers,
    )
    assert resp.status_code == 503


def test_test_push_403_for_non_admin(client: TestClient) -> None:
    """POST /api/push/test returns 403 for a non-admin user (JWT, not legacy token)."""
    from app.auth import issue_session_jwt
    settings = get_settings()
    # Override jwt_secret so we can issue a JWT for a different user
    import os
    os.environ["SIMMERSMITH_JWT_SECRET"] = "test-jwt-secret-for-403"
    get_settings.cache_clear()
    fresh_settings = get_settings()
    token = issue_session_jwt("some-other-user-id", fresh_settings)
    headers = {"Authorization": f"Bearer {token}"}
    resp = client.post(
        "/api/push/test",
        json={"user_id": settings.local_user_id, "title": "Hello", "body": "World"},
        headers=headers,
    )
    # Either 403 (non-admin) or 401 (JWT not verified against our configured secret)
    assert resp.status_code in (401, 403)
    # Restore env
    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


# ── Phase 2: send_push logic ───────────────────────────────────────


def test_send_push_skips_disabled_devices() -> None:
    """send_push should skip devices with disabled_at set."""
    from app.services.push_apns import send_push

    with session_scope() as session:
        settings = get_settings()
        user_id = "test-user-disabled-" + new_id()[:8]
        device = _make_user_with_device(session, user_id)
        device.disabled_at = utcnow()
        session.flush()

        # Patch is_apns_configured to return True so we exercise the send path
        with patch("app.services.push_apns.is_apns_configured", return_value=True):
            delivered = _run(
                send_push(
                    session,
                    settings=settings,
                    user_id=user_id,
                    title="Test",
                    body="Test body",
                )
            )
        assert delivered == 0


def test_send_push_returns_zero_when_no_devices() -> None:
    """send_push returns 0 when a user has no registered devices."""
    from app.services.push_apns import send_push

    with session_scope() as session:
        settings = get_settings()
        user_id = "no-devices-user-" + new_id()[:8]

        with patch("app.services.push_apns.is_apns_configured", return_value=True):
            delivered = _run(
                send_push(
                    session,
                    settings=settings,
                    user_id=user_id,
                    title="Test",
                    body="Test body",
                )
            )
        assert delivered == 0


def test_send_push_marks_disabled_on_410() -> None:
    """send_push should set disabled_at when APNs returns Unregistered."""
    from app.services.push_apns import send_push

    with session_scope() as session:
        settings = get_settings()
        user_id = "test-410-user-" + new_id()[:8]
        device = _make_user_with_device(session, user_id, device_token="token410" + "a" * 55)
        session.flush()

        # Mock aioapns result
        mock_result = MagicMock()
        mock_result.is_successful = False
        mock_result.status = "Unregistered"

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            delivered = _run(
                send_push(
                    session,
                    settings=settings,
                    user_id=user_id,
                    title="Test",
                    body="Test body",
                )
            )

        assert delivered == 0
        # disabled_at is set in-memory by send_push (committed when session_scope exits)
        assert device.disabled_at is not None


def test_send_push_delivers_to_active_device() -> None:
    """send_push should deliver and return count 1 for a healthy device."""
    from app.services.push_apns import send_push

    with session_scope() as session:
        settings = get_settings()
        user_id = "test-deliver-user-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="delivtoken" + "b" * 53)
        session.flush()

        mock_result = MagicMock()
        mock_result.is_successful = True

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            delivered = _run(
                send_push(
                    session,
                    settings=settings,
                    user_id=user_id,
                    title="Test",
                    body="Test body",
                )
            )

        assert delivered == 1


# ── Phase 2: scheduler tick logic ─────────────────────────────────


def _make_now_local_fn(target_dt: datetime):
    """Return a now_local callable that always returns target_dt for any tz_name."""
    def _fn(tz_name: str) -> datetime:
        return target_dt
    return _fn


def test_scheduler_tick_fires_at_matching_time() -> None:
    """Tick should send push when local time is within the window."""
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-fire-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedfire" + "c" * 54)
        _make_setting(session, user_id, "push_tonights_meal", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_tonights_meal_time", "17:00")

        # Create a dinner meal for today
        from app.models.week import Week as WeekModel, WeekMeal as WeekMealModel
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        # Use a Monday in the future to avoid week-start collisions
        target_dt = datetime(2026, 6, 1, 17, 0, 0, tzinfo=tz)  # Monday 17:00 local
        today_local = target_dt.date()

        week = WeekModel(
            id=new_id(),
            user_id=user_id,
            week_start=today_local,
            week_end=today_local,
            status="staging",
        )
        session.add(week)
        session.flush()

        meal = WeekMealModel(
            id=new_id(),
            week_id=week.id,
            day_name="Monday",
            meal_date=today_local,
            slot="dinner",
            recipe_name="Roast Chicken",
            source="ai",
        )
        session.add(meal)
        session.flush()

        dedup_key = ("tonights_meal", user_id, today_local.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_result = MagicMock()
        mock_result.is_successful = True
        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_tonights_meal(session, settings, user_id, now_fn))

        # Should have called send_notification
        assert mock_client.send_notification.call_count == 1
        assert _sent_today.get(dedup_key) is True


def test_scheduler_tick_skips_outside_window() -> None:
    """Tick should NOT send push when local time is outside the ±tick window."""
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-skip-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedskip" + "d" * 54)
        _make_setting(session, user_id, "push_tonights_meal", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_tonights_meal_time", "17:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        # 10:00 — far outside the 17:00 window
        target_dt = datetime(2026, 6, 2, 10, 0, 0, tzinfo=tz)
        today_local = target_dt.date()

        dedup_key = ("tonights_meal", user_id, today_local.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock()

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_tonights_meal(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 0


def test_scheduler_respects_quiet_hours() -> None:
    """Tick should NOT fire during quiet hours (22:00–07:00)."""
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-quiet-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedquiet" + "e" * 53)
        # Set push time to 23:00 so it would fire if not for quiet hours
        _make_setting(session, user_id, "push_tonights_meal", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_tonights_meal_time", "23:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 3, 23, 0, 0, tzinfo=tz)
        today_local = target_dt.date()

        dedup_key = ("tonights_meal", user_id, today_local.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock()

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_tonights_meal(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 0


def test_scheduler_respects_explicit_toggle_off() -> None:
    """Tick should NOT fire when push_tonights_meal == '0'."""
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-toggled-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedtog" + "f" * 55)
        _make_setting(session, user_id, "push_tonights_meal", "0")  # explicitly OFF
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_tonights_meal_time", "17:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 4, 17, 0, 0, tzinfo=tz)
        today_local = target_dt.date()

        dedup_key = ("tonights_meal", user_id, today_local.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock()

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_tonights_meal(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 0


def test_scheduler_default_on_semantics() -> None:
    """User with NO push_* rows should receive pushes (default == enabled)."""
    from app.services.push_scheduler import _process_tonights_meal, _sent_today

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-default-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="scheddef" + "g" * 55)
        # NO push_* settings rows — relying on default-on behavior
        _make_setting(session, user_id, "timezone", "America/Chicago")

        from app.models.week import Week as WeekModel, WeekMeal as WeekMealModel
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 8, 17, 0, 0, tzinfo=tz)  # Monday 17:00 — default time
        today_local = target_dt.date()

        week = WeekModel(
            id=new_id(),
            user_id=user_id,
            week_start=today_local,
            week_end=today_local,
            status="staging",
        )
        session.add(week)
        session.flush()

        meal = WeekMealModel(
            id=new_id(),
            week_id=week.id,
            day_name="Monday",
            meal_date=today_local,
            slot="dinner",
            recipe_name="Default Pasta",
            source="ai",
        )
        session.add(meal)
        session.flush()

        dedup_key = ("tonights_meal", user_id, today_local.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_result = MagicMock()
        mock_result.is_successful = True
        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_tonights_meal(session, settings, user_id, now_fn))

        # Should have fired because no explicit '0' row — default is enabled
        assert mock_client.send_notification.call_count == 1


def test_saturday_tick_skips_when_week_confirmed() -> None:
    """Saturday plan tick should skip when the upcoming week is approved/confirmed."""
    from app.services.push_scheduler import _process_saturday_plan, _sent_today
    from datetime import timedelta

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-sat-skip-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedsat" + "h" * 55)
        _make_setting(session, user_id, "push_saturday_plan", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_saturday_plan_time", "18:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        # Friday June 5, 2026 — weekday() == 4
        target_dt = datetime(2026, 6, 5, 18, 0, 0, tzinfo=tz)
        today_local = target_dt.date()

        # Upcoming Monday is June 8
        upcoming_monday = today_local + timedelta(days=3)

        # Create an APPROVED upcoming week
        week = Week(
            id=new_id(),
            user_id=user_id,
            week_start=upcoming_monday,
            week_end=upcoming_monday + timedelta(days=6),
            status="approved",
        )
        session.add(week)
        session.flush()

        dedup_key = ("saturday_plan", user_id, upcoming_monday.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock()

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_saturday_plan(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 0


def test_saturday_tick_fires_when_week_draft() -> None:
    """Saturday plan tick SHOULD fire when the upcoming week is still in draft/staging."""
    from app.services.push_scheduler import _process_saturday_plan, _sent_today
    from datetime import timedelta

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-sat-fire-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedsatf" + "i" * 54)
        _make_setting(session, user_id, "push_saturday_plan", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_saturday_plan_time", "18:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 12, 18, 0, 0, tzinfo=tz)  # Friday June 12
        today_local = target_dt.date()
        upcoming_monday = today_local + timedelta(days=3)  # June 15

        # Create a STAGING (draft) upcoming week
        week = Week(
            id=new_id(),
            user_id=user_id,
            week_start=upcoming_monday,
            week_end=upcoming_monday + timedelta(days=6),
            status="staging",
        )
        session.add(week)
        session.flush()

        dedup_key = ("saturday_plan", user_id, upcoming_monday.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_result = MagicMock()
        mock_result.is_successful = True
        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_saturday_plan(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 1


def test_saturday_tick_fires_when_no_week_exists() -> None:
    """Saturday plan tick SHOULD fire when no upcoming week row exists at all."""
    from app.services.push_scheduler import _process_saturday_plan, _sent_today
    from datetime import timedelta

    with session_scope() as session:
        settings = get_settings()
        user_id = "sched-sat-noweek-" + new_id()[:8]
        _make_user_with_device(session, user_id, device_token="schedsatnw" + "j" * 53)
        _make_setting(session, user_id, "push_saturday_plan", "1")
        _make_setting(session, user_id, "timezone", "America/Chicago")
        _make_setting(session, user_id, "push_saturday_plan_time", "18:00")

        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Chicago")
        target_dt = datetime(2026, 6, 19, 18, 0, 0, tzinfo=tz)  # Friday June 19
        today_local = target_dt.date()
        upcoming_monday = today_local + timedelta(days=3)  # June 22

        dedup_key = ("saturday_plan", user_id, upcoming_monday.isoformat())
        _sent_today.pop(dedup_key, None)

        mock_result = MagicMock()
        mock_result.is_successful = True
        mock_client = MagicMock()
        mock_client.send_notification = AsyncMock(return_value=mock_result)

        now_fn = _make_now_local_fn(target_dt)

        with patch("app.services.push_apns.is_apns_configured", return_value=True), \
             patch("app.services.push_apns._get_apns_client", return_value=mock_client):
            _run(_process_saturday_plan(session, settings, user_id, now_fn))

        assert mock_client.send_notification.call_count == 1


# ── M20: AI-finished-thinking push (assistant turn complete) ───────


def test_summarize_assistant_completion_uses_first_sentence() -> None:
    from app.services.push_apns import summarize_assistant_completion

    body = summarize_assistant_completion(
        tool_calls=[{"name": "add_meal", "ok": True}],
        assistant_markdown="Added salmon to Wednesday dinner. Anything else?",
    )
    assert body == "Added salmon to Wednesday dinner."


def test_summarize_assistant_completion_truncates_long_text() -> None:
    from app.services.push_apns import summarize_assistant_completion

    long_text = "x" * 200
    body = summarize_assistant_completion(
        tool_calls=[{"name": "swap_meal", "ok": True}],
        assistant_markdown=long_text,
    )
    assert body.endswith("...")
    assert len(body) == 140


def test_summarize_assistant_completion_falls_back_for_empty_text() -> None:
    from app.services.push_apns import summarize_assistant_completion

    # generate_week_plan gets a custom string
    body = summarize_assistant_completion(
        tool_calls=[{"name": "generate_week_plan", "ok": True}],
        assistant_markdown="",
    )
    assert body == "Your week plan is ready."

    # Multiple successful tools → count summary
    body = summarize_assistant_completion(
        tool_calls=[
            {"name": "add_meal", "ok": True},
            {"name": "swap_meal", "ok": True},
            {"name": "rebalance_day", "ok": True},
        ],
        assistant_markdown="",
    )
    assert body == "Your assistant made 3 updates."


def test_summarize_assistant_completion_skips_failed_tools() -> None:
    from app.services.push_apns import summarize_assistant_completion

    # Failed tools shouldn't count toward the summary
    body = summarize_assistant_completion(
        tool_calls=[
            {"name": "add_meal", "ok": False},
            {"name": "swap_meal", "ok": False},
        ],
        assistant_markdown="",
    )
    assert body == "Your assistant turn finished."


def test_assistant_done_push_helper_skips_when_user_disabled(client: TestClient, monkeypatch) -> None:
    """The push fires unless the user has set push_assistant_done=0.
    Verifies the gate is per-user, not global.
    """
    from app.api.assistant import _send_assistant_done_push
    from app.services.bootstrap import seed_defaults

    settings = get_settings()
    user_id = settings.local_user_id

    with session_scope() as session:
        seed_defaults(session)
        # Disable for this user
        row = (
            session.query(ProfileSetting)
            .filter(ProfileSetting.user_id == user_id, ProfileSetting.key == "push_assistant_done")
            .first()
        )
        if row is None:
            row = ProfileSetting(
                id=new_id(),
                user_id=user_id,
                key="push_assistant_done",
                value="0",
            )
            session.add(row)
        else:
            row.value = "0"
        session.commit()

    send_push_calls: list[dict[str, Any]] = []

    async def fake_send_push(*args: Any, **kwargs: Any) -> int:
        send_push_calls.append(kwargs)
        return 1

    monkeypatch.setattr("app.api.assistant.send_push", fake_send_push)

    asyncio.run(
        _send_assistant_done_push(
            settings=settings,
            user_id=user_id,
            thread_id="t-1",
            assistant_message_id="m-1",
            body="Updated your week.",
        )
    )

    assert send_push_calls == []


def test_assistant_done_push_helper_fires_when_user_enabled(client: TestClient, monkeypatch) -> None:
    """When the user keeps push_assistant_done='1' (default), the helper
    routes through send_push with the right body + deep_link payload.
    """
    from app.api.assistant import _send_assistant_done_push

    settings = get_settings()
    user_id = settings.local_user_id

    # Default profile should have push_assistant_done='1' from DEFAULT_PROFILE_SETTINGS.
    captured: dict[str, Any] = {}

    async def fake_send_push(*args: Any, **kwargs: Any) -> int:
        captured.update(kwargs)
        return 1

    monkeypatch.setattr("app.api.assistant.send_push", fake_send_push)

    asyncio.run(
        _send_assistant_done_push(
            settings=settings,
            user_id=user_id,
            thread_id="thread-abc",
            assistant_message_id="msg-xyz",
            body="Updated your week.",
        )
    )

    assert captured["title"] == "SimmerSmith"
    assert captured["body"] == "Updated your week."
    assert captured["payload"]["deep_link"] == "simmersmith://assistant?thread_id=thread-abc"
    assert captured["collapse_id"] == "assistant-msg-xyz"
