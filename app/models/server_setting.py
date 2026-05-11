"""Build 94 — global server settings, editable from the admin site.

Differs from ``ProfileSetting`` (per-user) and from ``app.config.Settings``
(env-driven). These are tunable knobs the operator wants to flip
without redeploying: free-tier limits, AI provider model defaults,
trial-mode toggle, etc.

Key/value as strings to stay schema-light; readers parse via
``app.services.server_settings`` typed accessors with sane defaults.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class ServerSetting(Base):
    __tablename__ = "server_settings"

    key: Mapped[str] = mapped_column(String(120), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="", nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )
