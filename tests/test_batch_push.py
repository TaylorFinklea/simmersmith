"""Push lane — APNs 410 (Unregistered) detection by HTTP status code.

Covers finding #11 (bug bash 2026-06-13):
- aioapns NotificationResult puts the HTTP status CODE in `status` ("410")
  and the reason ("Unregistered") in `description`. send_push must detect a
  dead token by code, not by reason, so the row is soft-disabled and pruned.
"""
from __future__ import annotations

import asyncio
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

from app.config import get_settings
from app.db import session_scope
from app.models._base import new_id, utcnow
from app.models.push import PushDevice


def _run(coro) -> Any:
    return asyncio.run(coro)


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


def _result(*, is_successful: bool, status: str, description: str) -> MagicMock:
    """Build an aioapns-shaped NotificationResult mock (status=HTTP code)."""
    mock_result = MagicMock()
    mock_result.is_successful = is_successful
    mock_result.status = status
    mock_result.description = description
    return mock_result


def _send(session, settings, user_id: str, mock_result: MagicMock) -> int:
    mock_client = MagicMock()
    mock_client.send_notification = AsyncMock(return_value=mock_result)
    from app.services.push_apns import send_push

    with patch("app.services.push_apns.is_apns_configured", return_value=True), \
         patch("app.services.push_apns._get_apns_client", return_value=mock_client):
        return _run(
            send_push(
                session,
                settings=settings,
                user_id=user_id,
                title="Test",
                body="Test body",
            )
        )


def test_410_status_code_soft_disables_device() -> None:
    """status='410' (real aioapns contract) flips disabled_at."""
    with session_scope() as session:
        settings = get_settings()
        user_id = "batch-410-code-" + new_id()[:8]
        device = _make_user_with_device(session, user_id, device_token="t410code" + "a" * 55)
        session.flush()

        delivered = _send(
            session,
            settings,
            user_id,
            _result(is_successful=False, status="410", description="Unregistered"),
        )

        assert delivered == 0
        assert device.disabled_at is not None


def test_unregistered_description_soft_disables_device() -> None:
    """description='Unregistered' also flips disabled_at (defensive OR branch)."""
    with session_scope() as session:
        settings = get_settings()
        user_id = "batch-410-desc-" + new_id()[:8]
        device = _make_user_with_device(session, user_id, device_token="t410desc" + "b" * 55)
        session.flush()

        delivered = _send(
            session,
            settings,
            user_id,
            _result(is_successful=False, status="410", description="Unregistered"),
        )

        assert delivered == 0
        assert device.disabled_at is not None


def test_other_apns_error_does_not_disable_device() -> None:
    """A non-410 APNs failure (e.g. 400 BadDeviceToken) leaves disabled_at None."""
    with session_scope() as session:
        settings = get_settings()
        user_id = "batch-400-err-" + new_id()[:8]
        device = _make_user_with_device(session, user_id, device_token="t400err1" + "c" * 55)
        session.flush()

        delivered = _send(
            session,
            settings,
            user_id,
            _result(is_successful=False, status="400", description="BadDeviceToken"),
        )

        assert delivered == 0
        assert device.disabled_at is None


def test_successful_delivery_does_not_disable_device() -> None:
    """A successful send delivers and never trips the 410 branch."""
    with session_scope() as session:
        settings = get_settings()
        user_id = "batch-200-ok-" + new_id()[:8]
        device = _make_user_with_device(session, user_id, device_token="t200okay" + "d" * 55)
        session.flush()

        delivered = _send(
            session,
            settings,
            user_id,
            _result(is_successful=True, status="200", description=""),
        )

        assert delivered == 1
        assert device.disabled_at is None
