"""HouseholdSetting (M21) — household-scoped key/value store.

Mirrors `ProfileSetting`'s shape but keyed by `household_id`. Holds keys
that describe the household's identity and shared planning preferences
(name, members count, timezone, week_start_day, store info, etc.).
Per-user settings (push toggles, image_provider, ai_provider_mode,
user_region) stay in `profile_settings`.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class HouseholdSetting(Base):
    __tablename__ = "household_settings"

    household_id: Mapped[str] = mapped_column(
        String(36),
        ForeignKey("households.id", ondelete="CASCADE"),
        primary_key=True,
    )
    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="", nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, nullable=False
    )
