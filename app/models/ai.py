from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models._base import new_id, utcnow

if TYPE_CHECKING:
    from app.models.recipe import Recipe
    from app.models.week import Week


class AIRun(Base):
    __tablename__ = "ai_runs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    week_id: Mapped[str | None] = mapped_column(ForeignKey("weeks.id", ondelete="CASCADE"), nullable=True)
    run_type: Mapped[str] = mapped_column(String(32), default="draft", nullable=False)
    model: Mapped[str] = mapped_column(String(120), default="skill-chat", nullable=False)
    prompt: Mapped[str] = mapped_column(Text, default="", nullable=False)
    status: Mapped[str] = mapped_column(String(32), default="completed", nullable=False)
    request_payload: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    response_payload: Mapped[str] = mapped_column(Text, default="{}", nullable=False)
    error: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    week: Mapped["Week | None"] = relationship(back_populates="ai_runs")


class AssistantThread(Base):
    __tablename__ = "assistant_threads"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(255), default="", nullable=False)
    preview: Mapped[str] = mapped_column(Text, default="", nullable=False)
    provider_thread_id: Mapped[str] = mapped_column(String(120), default="", nullable=False)
    thread_kind: Mapped[str] = mapped_column(String(24), default="chat", nullable=False)
    linked_week_id: Mapped[str | None] = mapped_column(
        ForeignKey("weeks.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, nullable=False
    )
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    messages: Mapped[list["AssistantMessage"]] = relationship(
        back_populates="thread",
        cascade="all, delete-orphan",
        order_by=lambda: AssistantMessage.created_at,
    )
    linked_week: Mapped["Week | None"] = relationship(foreign_keys=[linked_week_id])


class AssistantMessage(Base):
    __tablename__ = "assistant_messages"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    thread_id: Mapped[str] = mapped_column(ForeignKey("assistant_threads.id", ondelete="CASCADE"), nullable=False, index=True)
    role: Mapped[str] = mapped_column(String(20), default="assistant", nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="completed", nullable=False)
    content_markdown: Mapped[str] = mapped_column(Text, default="", nullable=False)
    recipe_draft_json: Mapped[str] = mapped_column(Text, default="", nullable=False)
    tool_calls_json: Mapped[str] = mapped_column(Text, default="[]", nullable=False)
    attached_recipe_id: Mapped[str | None] = mapped_column(
        ForeignKey("recipes.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    error: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    thread: Mapped["AssistantThread"] = relationship(back_populates="messages")
    attached_recipe: Mapped["Recipe | None"] = relationship()
