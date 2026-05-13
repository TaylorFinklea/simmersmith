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
from app.models import PushDevice, Recipe, Subscription, UsageCounter, User, Week, utcnow
from app.services.image_usage import global_usage_summary
from app.services.server_settings import (
    KEY_ANTHROPIC_MODEL,
    KEY_FREE_TIER_LIMITS,
    KEY_OPENAI_MODEL,
    KEY_TRIAL_MODE,
    KEY_USAGE_COST_USD,
    admin_snapshot,
    delete_value,
    set_free_tier_limits,
    set_usage_cost_usd,
    set_value,
    usage_cost_usd,
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


def _previous_period_key(period: str) -> str:
    """`2026-05` → `2026-04`. Used by user-detail for the two-month view."""
    year, month = period.split("-")
    y, m = int(year), int(month)
    m -= 1
    if m == 0:
        m = 12
        y -= 1
    return f"{y:04d}-{m:02d}"


def _estimate_cost(totals: dict[str, int], rates: dict[str, float]) -> float:
    return round(sum(int(count) * float(rates.get(action, 0.0)) for action, count in totals.items()), 4)


def _subscription_payload(sub: Subscription | None) -> dict[str, Any] | None:
    """Shape a Subscription row for the admin UI. ``source`` is derived
    from whether an Apple transaction id is present so the UI can flag
    admin grants without an extra column."""
    if sub is None:
        return None
    return {
        "status": sub.status,
        "product_id": sub.product_id,
        "source": "admin" if sub.apple_original_transaction_id is None else "apple",
        "current_period_starts_at": sub.current_period_starts_at.isoformat(),
        "current_period_ends_at": sub.current_period_ends_at.isoformat(),
        "auto_renew": bool(sub.auto_renew),
        "cancelled_at": sub.cancelled_at.isoformat() if sub.cancelled_at else None,
        "admin_note": sub.admin_note,
        "created_at": sub.created_at.isoformat(),
        "updated_at": sub.updated_at.isoformat(),
    }


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

    rates = usage_cost_usd(session)
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
                "estimated_cost_usd": _estimate_cost(action_totals, rates),
            }
        )
    by_user.sort(key=lambda row: (-row["total"], row["email"] or row["user_id"]))

    return {
        "period": target_period,
        "totals": totals,
        "by_user": by_user,
        "estimated_cost_usd": _estimate_cost(totals, rates),
    }


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
            select(UsageCounter.user_id, UsageCounter.action, func.sum(UsageCounter.count))
            .where(UsageCounter.period_key == period)
            .group_by(UsageCounter.user_id, UsageCounter.action)
        ).all()
    )
    per_user_totals: dict[str, dict[str, int]] = {}
    for user_id, action, total in counter_rows:
        per_user_totals.setdefault(user_id, {})[action] = int(total)

    sub_rows = {
        sub.user_id: sub
        for sub in session.scalars(select(Subscription)).all()
    }
    rates = usage_cost_usd(session)

    payload = []
    for user in users:
        sub = sub_rows.get(user.id)
        totals = per_user_totals.get(user.id, {})
        payload.append(
            {
                "user_id": user.id,
                "email": user.email,
                "display_name": user.display_name,
                "created_at": user.created_at.isoformat(),
                "monthly_usage": sum(totals.values()),
                "estimated_cost_usd": _estimate_cost(totals, rates),
                "subscription_status": sub.status if sub else "",
                "subscription_product": sub.product_id if sub else "",
                "subscription_source": (
                    "admin" if sub and sub.apple_original_transaction_id is None
                    else ("apple" if sub else "")
                ),
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

    if "usage_cost_usd" in payload:
        value = payload["usage_cost_usd"]
        if value is None:
            delete_value(session, KEY_USAGE_COST_USD)
        elif isinstance(value, dict):
            try:
                set_usage_cost_usd(session, {str(k): float(v) for k, v in value.items()})
            except (TypeError, ValueError) as exc:
                raise HTTPException(status_code=400, detail=f"usage_cost_usd values must be numbers: {exc}") from exc
        else:
            raise HTTPException(status_code=400, detail="usage_cost_usd must be an object or null")

    session.commit()
    return admin_snapshot(session, settings)


# ---------------------------------------------------------------------------
# Build 95 — admin user-detail + manual subscription overrides
# ---------------------------------------------------------------------------


@router.get("/users/{user_id}")
def admin_user_detail(
    user_id: str,
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """Per-user diagnostic snapshot for the admin site.

    Returns the user, their subscription, this+previous month
    usage counters (per action) with cost estimates, and rough
    inventory counts (recipes / weeks / active push devices).
    """
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    this_period = _period_key()
    prev_period = _previous_period_key(this_period)
    rates = usage_cost_usd(session)

    counter_rows = list(
        session.execute(
            select(UsageCounter.period_key, UsageCounter.action, func.sum(UsageCounter.count))
            .where(
                UsageCounter.user_id == user_id,
                UsageCounter.period_key.in_([this_period, prev_period]),
            )
            .group_by(UsageCounter.period_key, UsageCounter.action)
        ).all()
    )
    usage_by_period: dict[str, dict[str, int]] = {this_period: {}, prev_period: {}}
    for period, action, total in counter_rows:
        usage_by_period.setdefault(period, {})[action] = int(total)

    recipe_count = int(
        session.scalar(select(func.count()).select_from(Recipe).where(Recipe.user_id == user_id)) or 0
    )
    week_count = int(
        session.scalar(select(func.count()).select_from(Week).where(Week.user_id == user_id)) or 0
    )
    active_device_count = int(
        session.scalar(
            select(func.count()).select_from(PushDevice).where(
                PushDevice.user_id == user_id,
                PushDevice.disabled_at.is_(None),
            )
        ) or 0
    )

    sub = session.scalar(select(Subscription).where(Subscription.user_id == user_id))

    return {
        "user": {
            "id": user.id,
            "email": user.email,
            "display_name": user.display_name,
            "created_at": user.created_at.isoformat(),
            "has_apple_sign_in": bool(user.apple_sub),
            "has_google_sign_in": bool(user.google_sub),
        },
        "subscription": _subscription_payload(sub),
        "usage": {
            "this_period": {
                "period": this_period,
                "totals": usage_by_period[this_period],
                "total": sum(usage_by_period[this_period].values()),
                "estimated_cost_usd": _estimate_cost(usage_by_period[this_period], rates),
            },
            "previous_period": {
                "period": prev_period,
                "totals": usage_by_period[prev_period],
                "total": sum(usage_by_period[prev_period].values()),
                "estimated_cost_usd": _estimate_cost(usage_by_period[prev_period], rates),
            },
        },
        "inventory": {
            "recipes": recipe_count,
            "weeks": week_count,
            "active_push_devices": active_device_count,
        },
    }


def _parse_until(raw: str | None) -> datetime:
    """Validate the operator-supplied 'pro until' timestamp. Accepts an
    ISO 8601 date or datetime; bare dates resolve to UTC midnight."""
    if not raw:
        raise HTTPException(status_code=400, detail="'until' is required for grant_pro")
    try:
        # Bare YYYY-MM-DD via fromisoformat returns a naive datetime at midnight
        parsed = datetime.fromisoformat(raw)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid 'until' datetime: {exc}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    if parsed <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail="'until' must be in the future")
    return parsed


@router.post("/users/{user_id}/subscription")
def admin_user_subscription_override(
    user_id: str,
    payload: dict[str, Any] = Body(...),
    session: Session = Depends(get_session),
    _: None = Depends(require_admin_bearer),
) -> dict[str, Any]:
    """Manually grant / extend / revoke Pro for a user.

    Body:
        ``{"action": "grant_pro", "until": "YYYY-MM-DD[Thh:mm:ssZ]",
        "note": "..."}`` — creates or updates an admin-source
        subscription row whose ``current_period_ends_at`` is the
        supplied moment. ``apple_original_transaction_id`` is set to
        ``NULL`` so the next legitimate Apple webhook will replace
        this grant.

        ``{"action": "revoke"}`` — sets ``status="revoked"`` and
        ``cancelled_at=now``. Leaves the row in place so the audit
        trail survives.
    """
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    action = (payload or {}).get("action")
    if action not in {"grant_pro", "revoke"}:
        raise HTTPException(status_code=400, detail="action must be 'grant_pro' or 'revoke'")

    sub = session.scalar(select(Subscription).where(Subscription.user_id == user_id))

    if action == "grant_pro":
        until = _parse_until(payload.get("until"))
        note = (payload.get("note") or "").strip() or None
        product_id = (payload.get("product_id") or "admin.pro").strip() or "admin.pro"
        now = utcnow()
        if sub is None:
            sub = Subscription(
                user_id=user_id,
                product_id=product_id,
                apple_original_transaction_id=None,
                status="active",
                current_period_starts_at=now,
                current_period_ends_at=until,
                auto_renew=False,
                raw_payload_json="{}",
                admin_note=note,
            )
            session.add(sub)
        else:
            # Preserve Apple data on existing rows when extending —
            # operator can promote an Apple sub's end date if they
            # want, but we never NULL out a real transaction id.
            sub.status = "active"
            sub.current_period_ends_at = until
            sub.cancelled_at = None
            sub.admin_note = note
            sub.updated_at = now
    elif action == "revoke":
        if sub is None:
            raise HTTPException(status_code=404, detail="No subscription to revoke")
        sub.status = "revoked"
        sub.cancelled_at = utcnow()
        sub.updated_at = utcnow()

    session.commit()
    session.refresh(sub)
    return {
        "subscription": _subscription_payload(sub),
    }
