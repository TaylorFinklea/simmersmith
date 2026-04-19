"""Freemium gate: Pro-vs-free entitlement + monthly usage counters."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.models import Subscription, UsageCounter, new_id, utcnow


# Action identifiers used both in the `usage_counters.action` column and in
# the HTTP 402 payload so the iOS client knows which flow triggered the
# paywall.
ACTION_AI_GENERATE = "ai_generate"
ACTION_PRICING_FETCH = "pricing_fetch"
ACTION_REBALANCE_DAY = "rebalance_day"
ACTION_RECIPE_IMPORT = "recipe_import"

GATED_ACTIONS = {
    ACTION_AI_GENERATE,
    ACTION_PRICING_FETCH,
    ACTION_REBALANCE_DAY,
    ACTION_RECIPE_IMPORT,
}

# Starting defaults. These are the numbers the spec suggested; they live in
# one place so we can tune them server-side without re-shipping the iOS app.
FREE_TIER_LIMITS: dict[str, int] = {
    ACTION_AI_GENERATE: 1,
    ACTION_PRICING_FETCH: 1,
    ACTION_REBALANCE_DAY: 0,
    ACTION_RECIPE_IMPORT: 5,
}


@dataclass(frozen=True)
class UsageSummary:
    action: str
    limit: int
    used: int

    @property
    def remaining(self) -> int:
        return max(self.limit - self.used, 0)

    def as_payload(self) -> dict[str, int | str]:
        return {
            "action": self.action,
            "limit": self.limit,
            "used": self.used,
            "remaining": self.remaining,
        }


class UsageLimitReached(HTTPException):
    """HTTP 402 with a structured body the iOS client can decode."""

    def __init__(self, *, action: str, limit: int, used: int) -> None:
        super().__init__(
            status_code=status.HTTP_402_PAYMENT_REQUIRED,
            detail={
                "message": (
                    "You've used this month's free allowance. "
                    "Subscribe to SimmerSmith Pro to continue."
                ),
                "action": action,
                "limit": limit,
                "used": used,
            },
        )


def _period_key(now: datetime | None = None) -> str:
    instant = now or datetime.now(timezone.utc)
    return instant.strftime("%Y-%m")


def is_open_mode(settings: Settings | None = None) -> bool:
    """Matches auth.get_current_user's "no auth configured" fall-through.

    In open mode (dev + tests) the gate is skipped so local callers can run
    freely. Production has both jwt_secret and api_token set.
    """
    settings = settings or get_settings()
    return not bool(settings.jwt_secret) and not bool(settings.api_token.strip())


def is_trial_pro(settings: Settings | None = None) -> bool:
    """The temporary "free Pro for everyone during beta" switch.

    Controlled by the `SIMMERSMITH_TRIAL_MODE_ENABLED` env var on the
    backend. Separate from real paid Pro so the iOS client can render
    promotional copy instead of the usual "you're subscribed" row.
    """
    settings = settings or get_settings()
    return bool(settings.trial_mode_enabled)


def is_pro(session: Session, user_id: str, *, now: datetime | None = None, settings: Settings | None = None) -> bool:
    if is_trial_pro(settings):
        return True
    sub = session.scalar(select(Subscription).where(Subscription.user_id == user_id))
    if sub is None:
        return False
    if sub.status not in {"active", "in_grace"}:
        return False
    instant = now or datetime.now(timezone.utc)
    # SQLite (used in tests) stores datetimes naively; normalize to UTC so
    # comparisons don't raise.
    ends = sub.current_period_ends_at
    if ends.tzinfo is None:
        ends = ends.replace(tzinfo=timezone.utc)
    return ends > instant


def _counter_row(session: Session, user_id: str, action: str, period: str) -> UsageCounter | None:
    return session.scalar(
        select(UsageCounter).where(
            UsageCounter.user_id == user_id,
            UsageCounter.action == action,
            UsageCounter.period_key == period,
        )
    )


def current_usage(
    session: Session,
    user_id: str,
    action: str,
    *,
    now: datetime | None = None,
) -> UsageSummary:
    limit = FREE_TIER_LIMITS.get(action, 0)
    period = _period_key(now)
    row = _counter_row(session, user_id, action, period)
    used = row.count if row is not None else 0
    return UsageSummary(action=action, limit=limit, used=used)


def ensure_action_allowed(
    session: Session,
    user_id: str,
    action: str,
    *,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> None:
    """Raise UsageLimitReached (HTTP 402) when the user has hit the free-tier cap.

    No-op in open mode, for Pro users, or for actions that are not gated.
    """
    if action not in GATED_ACTIONS:
        return
    if is_open_mode(settings):
        return
    if is_pro(session, user_id, now=now):
        return
    summary = current_usage(session, user_id, action, now=now)
    if summary.used >= summary.limit:
        raise UsageLimitReached(
            action=summary.action,
            limit=summary.limit,
            used=summary.used,
        )


def increment_usage(
    session: Session,
    user_id: str,
    action: str,
    *,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> UsageSummary:
    """Bump the counter for a successful gated action.

    Pro users and open-mode environments do not accrue counts — we still
    want a record eventually for analytics, but that's a later phase. For
    now, free-tier counters drive the paywall and nothing else.
    """
    if action not in GATED_ACTIONS:
        return UsageSummary(action=action, limit=FREE_TIER_LIMITS.get(action, 0), used=0)
    if is_open_mode(settings):
        return current_usage(session, user_id, action, now=now)
    if is_pro(session, user_id, now=now):
        return current_usage(session, user_id, action, now=now)

    period = _period_key(now)
    row = _counter_row(session, user_id, action, period)
    if row is None:
        row = UsageCounter(
            id=new_id(),
            user_id=user_id,
            action=action,
            period_key=period,
            count=1,
        )
        session.add(row)
    else:
        row.count += 1
        row.updated_at = utcnow()
    session.flush()
    return UsageSummary(
        action=action,
        limit=FREE_TIER_LIMITS.get(action, 0),
        used=row.count,
    )


def all_usage_summaries(
    session: Session,
    user_id: str,
    *,
    now: datetime | None = None,
) -> list[UsageSummary]:
    return [
        current_usage(session, user_id, action, now=now)
        for action in sorted(GATED_ACTIONS)
    ]
