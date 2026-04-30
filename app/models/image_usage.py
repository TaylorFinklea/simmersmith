from __future__ import annotations

from datetime import datetime

from sqlalchemy import DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base
from app.models._base import utcnow


class ImageGenUsage(Base):
    """Per-call image generation telemetry for cost tracking.

    Recorded at generation time (success only). Each row captures provider,
    model, estimated cost, and trigger (save/backfill/regenerate) so the
    maintainer can verify the per-provider cost hypothesis and decide
    whether to flip the default provider.
    """
    __tablename__ = "image_gen_usage"

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    recipe_id: Mapped[str | None] = mapped_column(String(120), nullable=True)
    provider: Mapped[str] = mapped_column(String(16), nullable=False)
    model: Mapped[str] = mapped_column(String(80), nullable=False)
    est_cost_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    trigger: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False, index=True)
