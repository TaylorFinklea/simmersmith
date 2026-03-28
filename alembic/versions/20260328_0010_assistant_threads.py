"""Add assistant conversation storage.

Revision ID: 20260328_0010
Revises: 20260324_0009
Create Date: 2026-03-28 12:10:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260328_0010"
down_revision = "20260324_0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "assistant_threads",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("title", sa.String(length=255), nullable=False, server_default=""),
        sa.Column("preview", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "assistant_messages",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("thread_id", sa.String(length=36), nullable=False),
        sa.Column("role", sa.String(length=20), nullable=False, server_default="assistant"),
        sa.Column("status", sa.String(length=20), nullable=False, server_default="completed"),
        sa.Column("content_markdown", sa.Text(), nullable=False, server_default=""),
        sa.Column("recipe_draft_json", sa.Text(), nullable=False, server_default=""),
        sa.Column("attached_recipe_id", sa.String(length=120), nullable=True),
        sa.Column("error", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["attached_recipe_id"], ["recipes.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["thread_id"], ["assistant_threads.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_assistant_messages_thread_id", "assistant_messages", ["thread_id"], unique=False)
    op.create_index("ix_assistant_messages_attached_recipe_id", "assistant_messages", ["attached_recipe_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_assistant_messages_attached_recipe_id", table_name="assistant_messages")
    op.drop_index("ix_assistant_messages_thread_id", table_name="assistant_messages")
    op.drop_table("assistant_messages")
    op.drop_table("assistant_threads")
