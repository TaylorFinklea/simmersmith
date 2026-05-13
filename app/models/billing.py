from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class Subscription(Base):
    """Apple In-App Purchase auto-renewing subscription per user.

    One row per user. Absence of a row means the user is on the free tier.
    `status` comes from Apple's App Store Server Notifications v2 vocabulary
    reduced to: `active`, `expired`, `in_grace`, `refunded`, `revoked`.
    """
    __tablename__ = "subscriptions"

    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    product_id: Mapped[str] = mapped_column(String(120), nullable=False)
    # Nullable as of build 95: admin-granted rows have no Apple receipt.
    # Apple-billed rows still set this; the UNIQUE index permits multiple
    # NULLs in Postgres so admin grants don't collide.
    apple_original_transaction_id: Mapped[str | None] = mapped_column(
        String(40), unique=True, index=True, nullable=True
    )
    status: Mapped[str] = mapped_column(String(24), default="active", nullable=False)
    current_period_starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    current_period_ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    auto_renew: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    raw_payload_json: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    # Set on admin grants; null for Apple-billed rows.
    admin_note: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


class UsageCounter(Base):
    """Monthly usage counter per (user, action).

    Bumped on success only — a 500 from OpenAI does not burn a free-tier
    generation. `period_key` is `YYYY-MM` in UTC; rolling over to a new
    month implicitly resets limits.
    """
    __tablename__ = "usage_counters"
    __table_args__ = (
        UniqueConstraint("user_id", "action", "period_key", name="uq_usage_counters_user_action_period"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    action: Mapped[str] = mapped_column(String(40), nullable=False)
    period_key: Mapped[str] = mapped_column(String(7), nullable=False)
    count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )
