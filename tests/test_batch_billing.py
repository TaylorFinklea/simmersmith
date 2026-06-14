"""Batch bug-bash fixes — billing lane (T4/T5 entitlement webhook + /verify IDOR).

Two confirmed bugs in app/api/subscriptions.py:

  #4 The Apple webhook advanced ``last_transaction_id`` even for
     non-state-changing notifications (new_status None). A later
     EXPIRED/REFUND in the same billing period carries the SAME
     transactionId, so it then looked stale and was dropped — the user
     kept Pro after expiry/refund.

  #5 /verify migrated a Subscription row to the caller with no ownership
     check (account takeover / IDOR when the iOS client doesn't set
     appAccountToken, which it currently never does).

Real Apple JWS can't be forged, so we drive the routes by monkeypatching
the verify/decode functions on the API module (mirroring
tests/test_subscription_webhook.py).
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

import app.api.subscriptions as subs_api
from app.auth import CurrentUser, get_current_user
from app.db import session_scope
from app.main import app
from app.models import Subscription
from app.services.entitlements import is_pro
from app.services.subscriptions import VerifiedTransaction

OTX = "OTX-batch-billing"
PERIOD_START = datetime(2026, 5, 1, tzinfo=timezone.utc)
PERIOD_END = datetime(2026, 6, 1, tzinfo=timezone.utc)
USER_A = "00000000-0000-0000-0000-00000000000a"
USER_B = "00000000-0000-0000-0000-00000000000b"


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _seed_sub(
    *,
    user_id: str = USER_A,
    last_txn: str = "100",
    status: str = "active",
    app_account_token: str | None = None,
    ends_at: datetime = PERIOD_END,
) -> None:
    with session_scope() as session:
        session.add(
            Subscription(
                user_id=user_id,
                product_id="simmersmith.pro.monthly",
                apple_original_transaction_id=OTX,
                status=status,
                current_period_starts_at=PERIOD_START,
                current_period_ends_at=ends_at,
                auto_renew=True,
                last_transaction_id=last_txn,
                app_account_token=app_account_token,
                raw_payload_json="{}",
            )
        )


def _sub_row() -> Subscription:
    with session_scope() as session:
        return session.scalar(
            select(Subscription).where(
                Subscription.apple_original_transaction_id == OTX
            )
        )


def _patch_webhook(
    monkeypatch,
    *,
    notif_type,
    subtype="",
    uuid="u1",
    txn_id="200",
    expires=PERIOD_END,
    app_account_token=None,
):
    monkeypatch.setattr(
        subs_api,
        "decode_signed_payload",
        lambda signed, settings: {
            "notificationType": notif_type,
            "subtype": subtype,
            "notificationUUID": uuid,
            "signedDate": None,
            "data": {"signedTransactionInfo": "inner-jws"},
        },
    )
    monkeypatch.setattr(
        subs_api,
        "verify_transaction_jws",
        lambda signed, settings: VerifiedTransaction(
            product_id="simmersmith.pro.monthly",
            original_transaction_id=OTX,
            purchase_date=PERIOD_START,
            expires_date=expires,
            transaction_id=txn_id,
            environment="Sandbox",
            raw={},
            app_account_token=app_account_token,
        ),
    )


def _patch_verify(monkeypatch, *, txn_id="200", app_account_token=None):
    monkeypatch.setattr(
        subs_api,
        "verify_transaction_jws",
        lambda signed, settings: VerifiedTransaction(
            product_id="simmersmith.pro.monthly",
            original_transaction_id=OTX,
            purchase_date=PERIOD_START,
            expires_date=PERIOD_END,
            transaction_id=txn_id,
            environment="Sandbox",
            raw={},
            app_account_token=app_account_token,
        ),
    )


def _as_user(user_id: str):
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=user_id, household_id=user_id
    )


# ── #4: webhook must not advance last_transaction_id on unmapped types ──


def test_unmapped_notification_does_not_advance_last_transaction_id(
    client, monkeypatch
) -> None:
    # A PRICE_INCREASE (new_status None) carries the period's current
    # transactionId. It must NOT bump last_transaction_id, otherwise the
    # later EXPIRED with the SAME id looks stale.
    _seed_sub(last_txn="100")
    _patch_webhook(monkeypatch, notif_type="PRICE_INCREASE", uuid="pi-1", txn_id="200")
    resp = client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"})
    assert resp.status_code == 204
    row = _sub_row()
    assert row.status == "active"
    # Regression assertion: the id was NOT advanced past what we last applied.
    assert row.last_transaction_id == "100"


def test_expired_after_unmapped_same_txn_id_still_applies(client, monkeypatch) -> None:
    # The end-to-end bug: PRICE_INCREASE then EXPIRED in the same period
    # share transactionId 200. After the fix the EXPIRED is still applied,
    # so the user loses Pro.
    _seed_sub(last_txn="100")
    _patch_webhook(monkeypatch, notif_type="PRICE_INCREASE", uuid="pi-2", txn_id="200")
    assert (
        client.post(
            "/api/subscriptions/apple-webhook", json={"signedPayload": "x"}
        ).status_code
        == 204
    )

    _patch_webhook(monkeypatch, notif_type="EXPIRED", uuid="exp-2", txn_id="200")
    assert (
        client.post(
            "/api/subscriptions/apple-webhook", json={"signedPayload": "x"}
        ).status_code
        == 204
    )

    row = _sub_row()
    assert row.status == "expired"
    with session_scope() as session:
        assert is_pro(session, USER_A) is False


def test_mapped_notification_still_advances_last_transaction_id(
    client, monkeypatch
) -> None:
    # A renewal (new_status active) is a real state change and SHOULD still
    # advance the applied transaction id.
    _seed_sub(last_txn="100", ends_at=PERIOD_END)
    far_future = datetime(2099, 1, 1, tzinfo=timezone.utc)
    _patch_webhook(
        monkeypatch, notif_type="DID_RENEW", uuid="renew-1", txn_id="300", expires=far_future
    )
    assert (
        client.post(
            "/api/subscriptions/apple-webhook", json={"signedPayload": "x"}
        ).status_code
        == 204
    )
    row = _sub_row()
    assert row.status == "active"
    assert row.last_transaction_id == "300"


# ── #5: /verify must not migrate another user's subscription row ──


def test_verify_rejects_takeover_of_another_users_row(client, monkeypatch) -> None:
    # User A owns the row. User B presents A's (newer) transaction with no
    # appAccountToken — the row must NOT be migrated to B.
    _seed_sub(user_id=USER_A, last_txn="100")
    _patch_verify(monkeypatch, txn_id="200", app_account_token=None)
    _as_user(USER_B)
    try:
        resp = client.post(
            "/api/subscriptions/verify",
            json={"signed_transaction": "jws"},
        )
    finally:
        app.dependency_overrides.pop(get_current_user, None)
    assert resp.status_code == 409
    # The row is untouched — still A's, still A's last_transaction_id.
    row = _sub_row()
    assert row.user_id == USER_A
    assert row.last_transaction_id == "100"


def test_verify_owner_can_still_apply_their_own_transaction(client, monkeypatch) -> None:
    # The legitimate owner re-verifying a newer transaction still works.
    _seed_sub(user_id=USER_A, last_txn="100")
    _patch_verify(monkeypatch, txn_id="200", app_account_token=None)
    _as_user(USER_A)
    try:
        resp = client.post(
            "/api/subscriptions/verify",
            json={"signed_transaction": "jws"},
        )
    finally:
        app.dependency_overrides.pop(get_current_user, None)
    assert resp.status_code == 200
    row = _sub_row()
    assert row.user_id == USER_A
    assert row.last_transaction_id == "200"


def test_verify_allows_rebind_on_matching_app_account_token(client, monkeypatch) -> None:
    # When the receipt positively binds to the caller via a matching
    # appAccountToken, the verify path may re-bind to that user.
    _seed_sub(user_id=USER_A, last_txn="100", app_account_token="tok-shared")
    _patch_verify(monkeypatch, txn_id="200", app_account_token="tok-shared")
    _as_user(USER_B)
    try:
        resp = client.post(
            "/api/subscriptions/verify",
            json={"signed_transaction": "jws"},
        )
    finally:
        app.dependency_overrides.pop(get_current_user, None)
    assert resp.status_code == 200
    row = _sub_row()
    assert row.user_id == USER_B
