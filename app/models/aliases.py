"""M26 Phase 3 — per-household term aliases (shorthand → expansion)."""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import new_id, utcnow


class HouseholdTermAlias(Base):
    __tablename__ = "household_term_aliases"
    __table_args__ = (
        UniqueConstraint("household_id", "term", name="uq_household_term_aliases_household_term"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    household_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    term: Mapped[str] = mapped_column(String(120), nullable=False)
    expansion: Mapped[str] = mapped_column(String(255), nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )
