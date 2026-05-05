from __future__ import annotations

from datetime import datetime

from sqlalchemy import Boolean, DateTime, Float, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import new_id, utcnow


class ProfileSetting(Base):
    __tablename__ = "profile_settings"

    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="", nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)


class Staple(Base):
    """Pantry items — always-in-stock ingredients that are filtered
    from meal-driven grocery aggregation. M28 extended this from a
    simple "staple" concept to full pantry tracking with typical-
    purchase quantity (informational) and optional recurring auto-
    add to weekly grocery lists.
    """
    __tablename__ = "staples"
    __table_args__ = (UniqueConstraint("user_id", "normalized_name", name="uq_staples_user_normalized_name"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    household_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    staple_name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    # M28 — pantry extension. typical_* is informational ("we buy a
    # 50 lb bag of flour") and surfaced on the iOS pantry editor.
    # recurring_* + cadence drive auto-add to weekly grocery.
    typical_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    typical_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    recurring_quantity: Mapped[float | None] = mapped_column(Float, nullable=True)
    recurring_unit: Mapped[str] = mapped_column(String(40), default="", nullable=False)
    # 'none' | 'weekly' | 'biweekly' | 'monthly'. 'none' = the row is
    # a pure staple (filtered from grocery, never auto-added).
    recurring_cadence: Mapped[str] = mapped_column(String(24), default="none", nullable=False)
    category: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    # Last time the recurring fold-in added this pantry item to a
    # week's grocery list. Lets biweekly/monthly cadences skip weeks
    # without re-applying.
    last_applied_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


class DietaryGoal(Base):
    """Per-user daily calorie + macro target used by the AI planner.

    One row per user (user_id is the primary key). Absence of a row means the
    user has not configured a goal and the planner falls back to
    preference-only behaviour.
    """
    __tablename__ = "dietary_goals"

    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    goal_type: Mapped[str] = mapped_column(String(24), default="maintain", nullable=False)
    daily_calories: Mapped[int] = mapped_column(Integer, nullable=False)
    protein_g: Mapped[int] = mapped_column(Integer, nullable=False)
    carbs_g: Mapped[int] = mapped_column(Integer, nullable=False)
    fat_g: Mapped[int] = mapped_column(Integer, nullable=False)
    fiber_g: Mapped[int | None] = mapped_column(Integer, nullable=True)
    notes: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )


class PreferenceSignal(Base):
    __tablename__ = "preference_signals"
    __table_args__ = (
        UniqueConstraint("user_id", "signal_type", "normalized_name", name="uq_preference_signals_user_type_name"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    signal_type: Mapped[str] = mapped_column(String(40), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), index=True, nullable=False)
    score: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    weight: Mapped[int] = mapped_column(Integer, default=3, nullable=False)
    rationale: Mapped[str] = mapped_column(Text, default="", nullable=False)
    source: Mapped[str] = mapped_column(String(40), default="user", nullable=False)
    active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )
