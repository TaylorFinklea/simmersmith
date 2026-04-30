"""PushDevice ORM model (M18 push notifications)."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class PushDevice(Base):
    __tablename__ = "push_devices"
    __table_args__ = (
        UniqueConstraint("user_id", "device_token", name="uq_push_devices_user_token"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    device_token: Mapped[str] = mapped_column(String(200), nullable=False)
    platform: Mapped[str] = mapped_column(String(16), nullable=False, default="ios")
    apns_environment: Mapped[str] = mapped_column(String(16), nullable=False, default="sandbox")
    bundle_id: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    disabled_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, default=None
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow, onupdate=utcnow
    )
