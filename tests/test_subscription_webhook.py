"""F23/F24: App Store webhook replay/dedup + terminal-status hardening.

Real Apple JWS can't be forged (F22), so we drive the route by
monkeypatching the two verify functions and assert the server-side
guards: notificationUUID dedup, stale-transaction ignore, and the
terminal-status period-window freeze.
"""
from __future__ import annotations

from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

import app.api.subscriptions as subs_api
from app.db import session_scope
from app.main import app
from app.models import ProcessedAppleNotification, Subscription
from app.services.subscriptions import VerifiedTransaction

OTX = "OTX-1"
FAR_FUTURE = datetime(2099, 1, 1, tzinfo=timezone.utc)
ORIG_END = datetime(2026, 6, 1, tzinfo=timezone.utc)


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _seed_sub(last_txn: str = "100", status: str = "active") -> None:
    with session_scope() as session:
        session.add(
            Subscription(
                user_id="00000000-0000-0000-0000-000000000001",
                product_id="simmersmith.pro.monthly",
                apple_original_transaction_id=OTX,
                status=status,
                current_period_starts_at=datetime(2026, 5, 1, tzinfo=timezone.utc),
                current_period_ends_at=ORIG_END,
                auto_renew=True,
                last_transaction_id=last_txn,
                raw_payload_json="{}",
            )
        )


def _patch(monkeypatch, *, notif_type, subtype="", uuid="u1", txn_id="200",
           expires=FAR_FUTURE, signed_date_ms=None):
    monkeypatch.setattr(
        subs_api, "decode_signed_payload",
        lambda signed, settings: {
            "notificationType": notif_type,
            "subtype": subtype,
            "notificationUUID": uuid,
            "signedDate": signed_date_ms,
            "data": {"signedTransactionInfo": "inner-jws"},
        },
    )
    monkeypatch.setattr(
        subs_api, "verify_transaction_jws",
        lambda signed, settings: VerifiedTransaction(
            product_id="simmersmith.pro.monthly",
            original_transaction_id=OTX,
            purchase_date=datetime(2026, 5, 2, tzinfo=timezone.utc),
            expires_date=expires,
            transaction_id=txn_id,
            environment="Sandbox",
            raw={},
        ),
    )


def _sub_row() -> Subscription:
    with session_scope() as session:
        return session.scalar(
            select(Subscription).where(
                Subscription.apple_original_transaction_id == OTX
            )
        )


def test_refund_does_not_advance_period_window(client, monkeypatch) -> None:
    _seed_sub()
    _patch(monkeypatch, notif_type="REFUND", uuid="refund-1")
    resp = client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"})
    assert resp.status_code == 204
    row = _sub_row()
    assert row.status == "refunded"
    # Period window frozen — NOT advanced to the far-future expires_date.
    assert row.current_period_ends_at.replace(tzinfo=timezone.utc) == ORIG_END


def test_renewal_advances_window(client, monkeypatch) -> None:
    _seed_sub()
    _patch(monkeypatch, notif_type="DID_RENEW", uuid="renew-1", txn_id="200")
    resp = client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"})
    assert resp.status_code == 204
    row = _sub_row()
    assert row.status == "active"
    assert row.current_period_ends_at.replace(tzinfo=timezone.utc) == FAR_FUTURE


def test_duplicate_notification_uuid_is_ignored(client, monkeypatch) -> None:
    _seed_sub()
    _patch(monkeypatch, notif_type="DID_RENEW", uuid="dup-1", txn_id="200")
    assert client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"}).status_code == 204
    # Second delivery of the same UUID, now claiming a refund — must be dropped.
    _patch(monkeypatch, notif_type="REFUND", uuid="dup-1", txn_id="201")
    assert client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"}).status_code == 204
    row = _sub_row()
    assert row.status == "active"  # the replayed REFUND was ignored
    with session_scope() as session:
        seen = session.scalars(
            select(ProcessedAppleNotification)
        ).all()
        assert sum(1 for s in seen if s.notification_uuid == "dup-1") == 1


def test_stale_transaction_is_ignored(client, monkeypatch) -> None:
    _seed_sub(last_txn="500")
    # An older transactionId than what we last applied — replay/out-of-order.
    _patch(monkeypatch, notif_type="REFUND", uuid="stale-1", txn_id="300")
    assert client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"}).status_code == 204
    assert _sub_row().status == "active"  # unchanged


def test_unmapped_notification_type_does_not_advance_window(client, monkeypatch) -> None:
    # M25: a type status_from_notification doesn't map (new_status None) must
    # NOT push the period window forward.
    _seed_sub(last_txn="100")
    _patch(monkeypatch, notif_type="PRICE_INCREASE", uuid="pi-1", txn_id="200")
    assert client.post("/api/subscriptions/apple-webhook", json={"signedPayload": "x"}).status_code == 204
    row = _sub_row()
    assert row.status == "active"
    assert row.current_period_ends_at.replace(tzinfo=timezone.utc) == ORIG_END  # unchanged


def test_production_drops_sandbox_verifier_when_disabled(monkeypatch) -> None:
    # M28: with Production + allow_sandbox False, only the Production verifier
    # is built (no Sandbox fallback), so a Sandbox receipt can't grant Pro.
    import app.services.subscriptions as svc

    monkeypatch.setenv("SIMMERSMITH_APPLE_IAP_BUNDLE_ID", "app.simmersmith")
    monkeypatch.setenv("SIMMERSMITH_APPLE_IAP_ENVIRONMENT", "Production")
    monkeypatch.setenv("SIMMERSMITH_APPLE_IAP_APP_APPLE_ID", "123456")
    monkeypatch.setenv("SIMMERSMITH_APPLE_IAP_ALLOW_SANDBOX", "false")
    from app.config import get_settings
    get_settings.cache_clear()
    try:
        verifiers = svc._verifiers_in_order(get_settings())
        assert len(verifiers) == 1  # production only — no sandbox fallback
    finally:
        get_settings.cache_clear()
