"""Freemium gate + subscription tests."""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import reset_db_state, session_scope
from app.models import Subscription, UsageCounter
from app.services.bootstrap import run_migrations, seed_defaults
from app.services.entitlements import (
    ACTION_AI_GENERATE,
    ACTION_PRICING_FETCH,
    ACTION_REBALANCE_DAY,
    FREE_TIER_LIMITS,
    UsageLimitReached,
    current_usage,
    ensure_action_allowed,
    increment_usage,
    is_open_mode,
    is_pro,
)
from app.services.subscriptions import (
    VerifiedTransaction,
    status_from_notification,
    upsert_subscription_from_transaction,
)


TEST_USER_ID = "00000000-0000-0000-0000-000000000001"


@pytest.fixture
def enforced_mode() -> None:
    """Force the gate on by pretending auth is configured."""
    os.environ["SIMMERSMITH_JWT_SECRET"] = "test-secret-not-blank"
    os.environ["SIMMERSMITH_API_TOKEN"] = "test-token"
    get_settings.cache_clear()
    reset_db_state()
    run_migrations()
    with session_scope() as session:
        seed_defaults(session)
    yield
    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    os.environ.pop("SIMMERSMITH_API_TOKEN", None)
    get_settings.cache_clear()


def test_open_mode_bypasses_gate() -> None:
    """Dev/test environments without auth never 402."""
    assert is_open_mode() is True
    with session_scope() as session:
        # Call the gate many times — it should never raise.
        for _ in range(10):
            ensure_action_allowed(session, TEST_USER_ID, ACTION_AI_GENERATE)


def test_free_tier_limit_blocks_after_first_use(enforced_mode) -> None:  # noqa: ARG001
    with session_scope() as session:
        ensure_action_allowed(session, TEST_USER_ID, ACTION_AI_GENERATE)
        increment_usage(session, TEST_USER_ID, ACTION_AI_GENERATE)
        # Second call should raise.
        with pytest.raises(UsageLimitReached) as excinfo:
            ensure_action_allowed(session, TEST_USER_ID, ACTION_AI_GENERATE)
        detail = excinfo.value.detail
        assert detail["action"] == ACTION_AI_GENERATE
        assert detail["limit"] == FREE_TIER_LIMITS[ACTION_AI_GENERATE]
        assert detail["used"] == 1


def test_pro_user_bypasses_gate(enforced_mode) -> None:  # noqa: ARG001
    with session_scope() as session:
        # Manually insert an active subscription.
        future = datetime.now(timezone.utc) + timedelta(days=30)
        session.add(
            Subscription(
                user_id=TEST_USER_ID,
                product_id="simmersmith.pro.monthly",
                apple_original_transaction_id="apple-original-1",
                status="active",
                current_period_starts_at=datetime.now(timezone.utc),
                current_period_ends_at=future,
                auto_renew=True,
            )
        )
        session.commit()

        assert is_pro(session, TEST_USER_ID) is True
        for _ in range(5):
            ensure_action_allowed(session, TEST_USER_ID, ACTION_AI_GENERATE)


def test_rebalance_gated_at_zero_free(enforced_mode) -> None:  # noqa: ARG001
    """Rebalance is a Pro-only action — free users can't even do it once."""
    with session_scope() as session:
        with pytest.raises(UsageLimitReached) as excinfo:
            ensure_action_allowed(session, TEST_USER_ID, ACTION_REBALANCE_DAY)
        assert excinfo.value.detail["limit"] == 0


def test_counters_scope_per_action_and_month(enforced_mode) -> None:  # noqa: ARG001
    """Ai_generate counter doesn't affect pricing counter."""
    with session_scope() as session:
        increment_usage(session, TEST_USER_ID, ACTION_AI_GENERATE)
        # Pricing still available.
        ensure_action_allowed(session, TEST_USER_ID, ACTION_PRICING_FETCH)
        assert current_usage(session, TEST_USER_ID, ACTION_PRICING_FETCH).used == 0


def test_usage_counter_idempotent_when_pro(enforced_mode) -> None:  # noqa: ARG001
    """Pro users do not accrue counts (yet)."""
    with session_scope() as session:
        future = datetime.now(timezone.utc) + timedelta(days=30)
        session.add(
            Subscription(
                user_id=TEST_USER_ID,
                product_id="simmersmith.pro.annual",
                apple_original_transaction_id="apple-original-2",
                status="active",
                current_period_starts_at=datetime.now(timezone.utc),
                current_period_ends_at=future,
            )
        )
        session.commit()
        increment_usage(session, TEST_USER_ID, ACTION_AI_GENERATE)
        rows = session.scalars(select(UsageCounter)).all()
        assert rows == []


def test_expired_subscription_does_not_count_as_pro(enforced_mode) -> None:  # noqa: ARG001
    with session_scope() as session:
        past = datetime.now(timezone.utc) - timedelta(days=2)
        session.add(
            Subscription(
                user_id=TEST_USER_ID,
                product_id="simmersmith.pro.monthly",
                apple_original_transaction_id="apple-original-3",
                status="expired",
                current_period_starts_at=past - timedelta(days=30),
                current_period_ends_at=past,
            )
        )
        session.commit()
        assert is_pro(session, TEST_USER_ID) is False


def test_grace_period_keeps_entitlement(enforced_mode) -> None:  # noqa: ARG001
    with session_scope() as session:
        future = datetime.now(timezone.utc) + timedelta(days=5)
        session.add(
            Subscription(
                user_id=TEST_USER_ID,
                product_id="simmersmith.pro.monthly",
                apple_original_transaction_id="apple-original-4",
                status="in_grace",
                current_period_starts_at=datetime.now(timezone.utc),
                current_period_ends_at=future,
            )
        )
        session.commit()
        assert is_pro(session, TEST_USER_ID) is True


def test_notification_type_status_mapping() -> None:
    assert status_from_notification("SUBSCRIBED", "INITIAL_BUY") == "active"
    assert status_from_notification("SUBSCRIBED", "RESUBSCRIBE") == "active"
    assert status_from_notification("DID_RENEW", None) == "active"
    assert status_from_notification("EXPIRED", None) == "expired"
    assert status_from_notification("REFUND", None) == "refunded"
    assert status_from_notification("REVOKE", None) == "revoked"
    assert status_from_notification("NOT_A_REAL_TYPE", None) is None


def test_upsert_subscription_migrates_between_users(client) -> None:  # noqa: ARG001
    """If the same originalTransactionId is seen under a different user_id,
    the row is migrated to the new user (latest auth wins)."""
    verified = VerifiedTransaction(
        product_id="simmersmith.pro.monthly",
        original_transaction_id="apple-tx-42",
        transaction_id="apple-tx-42",
        purchase_date=datetime.now(timezone.utc),
        expires_date=datetime.now(timezone.utc) + timedelta(days=30),
        environment="Sandbox",
        raw={"productId": "simmersmith.pro.monthly"},
    )
    with session_scope() as session:
        row_a = upsert_subscription_from_transaction(
            session, user_id="user-a", transaction=verified
        )
        assert row_a.user_id == "user-a"

        row_b = upsert_subscription_from_transaction(
            session, user_id="user-b", transaction=verified
        )
        assert row_b.user_id == "user-b"
        assert row_b.apple_original_transaction_id == "apple-tx-42"


def test_profile_response_exposes_is_pro_and_usage(client) -> None:
    body = client.get("/api/profile").json()
    assert "is_pro" in body
    assert "is_trial" in body
    assert "usage" in body
    # Open mode returns is_pro=False but the 4 gated actions appear so the
    # iOS client can render progress indicators even before paywall time.
    actions = {entry["action"] for entry in body["usage"]}
    assert actions == {
        ACTION_AI_GENERATE,
        ACTION_PRICING_FETCH,
        ACTION_REBALANCE_DAY,
        "recipe_import",
    }


def test_trial_mode_unlocks_pro_for_everyone(enforced_mode) -> None:  # noqa: ARG001
    """When SIMMERSMITH_TRIAL_MODE_ENABLED=true, any user is Pro."""
    os.environ["SIMMERSMITH_TRIAL_MODE_ENABLED"] = "true"
    get_settings.cache_clear()
    try:
        with session_scope() as session:
            # Fresh user has no subscription row, so normally would be free.
            assert is_pro(session, "nobody-in-particular") is True
            # Gate should be a no-op for every action.
            for _ in range(5):
                ensure_action_allowed(session, "nobody-in-particular", ACTION_AI_GENERATE)
    finally:
        os.environ.pop("SIMMERSMITH_TRIAL_MODE_ENABLED", None)
        get_settings.cache_clear()


def test_trial_mode_surfaces_is_trial_flag(client) -> None:
    os.environ["SIMMERSMITH_TRIAL_MODE_ENABLED"] = "true"
    get_settings.cache_clear()
    try:
        body = client.get("/api/profile").json()
        assert body["is_pro"] is True
        assert body["is_trial"] is True
    finally:
        os.environ.pop("SIMMERSMITH_TRIAL_MODE_ENABLED", None)
        get_settings.cache_clear()
