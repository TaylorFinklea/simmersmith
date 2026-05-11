"""Admin-only diagnostic endpoints. Gated by legacy bearer token."""
from __future__ import annotations

from datetime import datetime, timezone
from secrets import compare_digest
from typing import Any

from fastapi import APIRouter, Body, Depends, HTTPException, Query, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_session
from app.models import Subscription, UsageCounter, User
from app.services.image_usage import global_usage_summary
from app.services.server_settings import (
    KEY_ANTHROPIC_MODEL,
    KEY_FREE_TIER_LIMITS,
    KEY_OPENAI_MODEL,
    KEY_TRIAL_MODE,
    admin_snapshot,
    delete_value,
    set_free_tier_limits,
    set_value,
)


router = APIRouter(prefix="/api/admin", tags=["admin"])
bearer_scheme = HTTPBearer(auto_error=False)


def require_admin_bearer(
    authorization: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    settings: Settings = Depends(get_settings),
) -> None:
    """Dependency: require a valid legacy bearer token matching SIMMERSMITH_API_TOKEN.

    Raises 403 if the token is missing, invalid, or empty.
    """
    if not settings.api_token.strip():
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin token not configured",
        )
    if authorization is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Missing authorization header",
        )
    if not compare_digest(authorization.credentials, settings.api_token):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid token",
        )


@router.get("/image-usage")
def get_image_usage(
    days: int = Query(30, ge=1, le=365),
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict:
    """Global image generation telemetry (admin only).

    Returns per-provider aggregates and top users by image count.

    Query parameters:
        days: Window size in days (1-365). Default 30.

    Requires: Bearer token matching SIMMERSMITH_API_TOKEN.
    """
    return global_usage_summary(session, days=days)


# ---------------------------------------------------------------------------
# Build 94 — admin site endpoints (usage / users / settings)
# ---------------------------------------------------------------------------


def _period_key(now: datetime | None = None) -> str:
    instant = now or datetime.now(timezone.utc)
    return instant.strftime("%Y-%m")


@router.get("/usage")
def admin_usage_summary(
    period: str = Query("", description="YYYY-MM. Empty → current month."),
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """Aggregate AI usage across all users for the requested month.

    Returns:
        ``{"period": "YYYY-MM", "totals": {action: count, ...},
        "by_user": [{"user_id", "email", "display_name", "totals": {...}}, ...]}``

    The ``by_user`` list is sorted by total usage descending.
    """
    target_period = period.strip() or _period_key()

    rows = list(
        session.execute(
            select(
                UsageCounter.user_id,
                UsageCounter.action,
                func.sum(UsageCounter.count).label("count"),
            )
            .where(UsageCounter.period_key == target_period)
            .group_by(UsageCounter.user_id, UsageCounter.action)
        ).all()
    )

    totals: dict[str, int] = {}
    per_user: dict[str, dict[str, int]] = {}
    for user_id, action, count in rows:
        totals[action] = totals.get(action, 0) + int(count)
        per_user.setdefault(user_id, {})[action] = int(count)

    users_by_id = {
        user.id: user
        for user in session.scalars(
            select(User).where(User.id.in_(list(per_user.keys())))
        ).all()
    }

    by_user = []
    for user_id, action_totals in per_user.items():
        user = users_by_id.get(user_id)
        by_user.append(
            {
                "user_id": user_id,
                "email": user.email if user else "",
                "display_name": user.display_name if user else "",
                "totals": action_totals,
                "total": sum(action_totals.values()),
            }
        )
    by_user.sort(key=lambda row: (-row["total"], row["email"] or row["user_id"]))

    return {"period": target_period, "totals": totals, "by_user": by_user}


@router.get("/users")
def admin_users_list(
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """List every user with subscription status + current-month totals."""
    users = list(session.scalars(select(User).order_by(User.created_at.desc())).all())
    period = _period_key()

    counter_rows = list(
        session.execute(
            select(UsageCounter.user_id, func.sum(UsageCounter.count))
            .where(UsageCounter.period_key == period)
            .group_by(UsageCounter.user_id)
        ).all()
    )
    counts_by_user = {user_id: int(total) for user_id, total in counter_rows}

    sub_rows = {
        sub.user_id: sub
        for sub in session.scalars(select(Subscription)).all()
    }

    payload = []
    for user in users:
        sub = sub_rows.get(user.id)
        payload.append(
            {
                "user_id": user.id,
                "email": user.email,
                "display_name": user.display_name,
                "created_at": user.created_at.isoformat(),
                "monthly_usage": counts_by_user.get(user.id, 0),
                "subscription_status": sub.status if sub else "",
                "subscription_product": sub.product_id if sub else "",
            }
        )

    return {"period": period, "users": payload}


@router.get("/settings")
def admin_settings_get(
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """Read the editable server-settings snapshot."""
    return admin_snapshot(session, settings)


@router.patch("/settings")
def admin_settings_patch(
    payload: dict[str, Any] = Body(...),
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """Update the editable server settings. Accepts any subset of:

    - ``free_tier_limits``: ``{action: int}``. Pass ``null`` to clear
      back to the hard-coded default.
    - ``ai_openai_model``: string. Empty string clears the override.
    - ``ai_anthropic_model``: string. Empty string clears the override.
    - ``trial_mode_enabled``: bool. Pass ``null`` to clear the override
      so the env var takes over.
    """
    if "free_tier_limits" in payload:
        value = payload["free_tier_limits"]
        if value is None:
            delete_value(session, KEY_FREE_TIER_LIMITS)
        elif isinstance(value, dict):
            set_free_tier_limits(session, value)
        else:
            raise HTTPException(status_code=400, detail="free_tier_limits must be an object or null")

    if "ai_openai_model" in payload:
        value = payload["ai_openai_model"]
        if value in (None, ""):
            delete_value(session, KEY_OPENAI_MODEL)
        elif isinstance(value, str):
            set_value(session, KEY_OPENAI_MODEL, value.strip())
        else:
            raise HTTPException(status_code=400, detail="ai_openai_model must be a string")

    if "ai_anthropic_model" in payload:
        value = payload["ai_anthropic_model"]
        if value in (None, ""):
            delete_value(session, KEY_ANTHROPIC_MODEL)
        elif isinstance(value, str):
            set_value(session, KEY_ANTHROPIC_MODEL, value.strip())
        else:
            raise HTTPException(status_code=400, detail="ai_anthropic_model must be a string")

    if "trial_mode_enabled" in payload:
        value = payload["trial_mode_enabled"]
        if value is None:
            delete_value(session, KEY_TRIAL_MODE)
        elif isinstance(value, bool):
            set_value(session, KEY_TRIAL_MODE, "1" if value else "0")
        else:
            raise HTTPException(status_code=400, detail="trial_mode_enabled must be a boolean")

    session.commit()
    return admin_snapshot(session, settings)
