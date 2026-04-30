"""Image generation usage tracking and cost telemetry.

Provides row-level logging of image generation calls with per-provider
cost estimates, enabling dogfooders to verify the "Gemini saves money"
hypothesis before flipping the default provider.
"""
from __future__ import annotations

from datetime import timedelta

from sqlalchemy import and_, select
from sqlalchemy.orm import Session

from app.models import ImageGenUsage
from app.models._base import new_id, utcnow


# Cost estimates per image, in cents. Sourced from current pricing pages:
# - OpenAI gpt-image-1 (1024×1024, standard quality):
#   https://openai.com/pricing/image-models (as of 2026-04-30: $0.04 per image)
# - Google Gemini gemini-2.5-flash-image-preview:
#   https://ai.google.dev/pricing (as of 2026-04-30: ~1290 output image tokens
#   at ~$30/M = ~$0.039 ≈ 4¢ per image).
# Bump these constants if pricing changes, and add an ADR note to decisions.md.
_PROVIDER_COST_CENTS = {
    "openai": 4,
    "gemini": 4,
}


def record_image_gen(
    session: Session,
    *,
    user_id: str,
    recipe_id: str | None,
    provider: str,
    model: str,
    trigger: str,
) -> None:
    """Record a successful image generation event.

    Called from recipe save/backfill/regenerate routes after successful
    generation and before session.commit(). If the session rolls back,
    the row is not persisted (correct behavior for failures).

    Args:
        session: SQLAlchemy session (caller owns the transaction).
        user_id: The user who generated the image.
        recipe_id: The recipe being imaged (nullable if recipe was deleted).
        provider: 'openai' or 'gemini'.
        model: The actual model string (e.g. 'gpt-image-1').
        trigger: 'save', 'backfill', or 'regenerate'.
    """
    est_cost_cents = _PROVIDER_COST_CENTS.get(provider, 0)
    row = ImageGenUsage(
        id=new_id(),
        user_id=user_id,
        recipe_id=recipe_id,
        provider=provider,
        model=model,
        est_cost_cents=est_cost_cents,
        trigger=trigger,
    )
    session.add(row)


def usage_summary(session: Session, user_id: str, *, days: int = 30) -> dict:
    """Per-user image generation summary for the last N days.

    Returned by GET /api/profile and displayed in iOS Settings as:
    "This month: 38 images · ~$1.49 (22 Gemini · 16 OpenAI)".

    Returns:
        {
            "window_days": 30,
            "total_count": int,
            "total_cost_cents": int,
            "by_provider": [
                {"provider": "openai", "count": 16, "cost_cents": 64},
                {"provider": "gemini", "count": 22, "cost_cents": 88},
            ]
        }
    """
    cutoff = utcnow() - timedelta(days=days)
    rows = session.scalars(
        select(ImageGenUsage).where(
            and_(
                ImageGenUsage.user_id == user_id,
                ImageGenUsage.created_at >= cutoff,
            )
        )
    ).all()

    if not rows:
        return {
            "window_days": days,
            "total_count": 0,
            "total_cost_cents": 0,
            "by_provider": [],
        }

    # Aggregate by provider
    by_provider_dict: dict[str, tuple[int, int]] = {}  # provider -> (count, cost_cents)
    total_count = 0
    total_cost_cents = 0

    for row in rows:
        total_count += 1
        total_cost_cents += row.est_cost_cents
        if row.provider not in by_provider_dict:
            by_provider_dict[row.provider] = (0, 0)
        count, cost = by_provider_dict[row.provider]
        by_provider_dict[row.provider] = (count + 1, cost + row.est_cost_cents)

    # Sort by count descending
    by_provider = [
        {
            "provider": provider,
            "count": count,
            "cost_cents": cost,
        }
        for provider, (count, cost) in sorted(
            by_provider_dict.items(),
            key=lambda x: x[1][0],
            reverse=True,
        )
    ]

    return {
        "window_days": days,
        "total_count": total_count,
        "total_cost_cents": total_cost_cents,
        "by_provider": by_provider,
    }


def global_usage_summary(session: Session, *, days: int = 30, top_users: int = 10) -> dict:
    """Global image generation summary for the admin endpoint.

    Returns top N users by image count + global aggregates.

    Returns:
        {
            "window_days": 30,
            "total_count": int,
            "total_cost_cents": int,
            "by_provider": [...],
            "top_users": [
                {"user_id": "...", "count": 50, "cost_cents": 200},
                ...
            ]
        }
    """
    cutoff = utcnow() - timedelta(days=days)
    rows = session.scalars(
        select(ImageGenUsage).where(ImageGenUsage.created_at >= cutoff)
    ).all()

    if not rows:
        return {
            "window_days": days,
            "total_count": 0,
            "total_cost_cents": 0,
            "by_provider": [],
            "top_users": [],
        }

    # Global aggregates
    by_provider_dict: dict[str, tuple[int, int]] = {}
    by_user_dict: dict[str, tuple[int, int]] = {}
    total_count = 0
    total_cost_cents = 0

    for row in rows:
        total_count += 1
        total_cost_cents += row.est_cost_cents

        # Provider aggregates
        if row.provider not in by_provider_dict:
            by_provider_dict[row.provider] = (0, 0)
        count, cost = by_provider_dict[row.provider]
        by_provider_dict[row.provider] = (count + 1, cost + row.est_cost_cents)

        # User aggregates
        if row.user_id not in by_user_dict:
            by_user_dict[row.user_id] = (0, 0)
        count, cost = by_user_dict[row.user_id]
        by_user_dict[row.user_id] = (count + 1, cost + row.est_cost_cents)

    by_provider = [
        {
            "provider": provider,
            "count": count,
            "cost_cents": cost,
        }
        for provider, (count, cost) in sorted(
            by_provider_dict.items(),
            key=lambda x: x[1][0],
            reverse=True,
        )
    ]

    top_users = [
        {
            "user_id": user_id,
            "count": count,
            "cost_cents": cost,
        }
        for user_id, (count, cost) in sorted(
            by_user_dict.items(),
            key=lambda x: x[1][0],
            reverse=True,
        )[:top_users]
    ]

    return {
        "window_days": days,
        "total_count": total_count,
        "total_cost_cents": total_cost_cents,
        "by_provider": by_provider,
        "top_users": top_users,
    }
