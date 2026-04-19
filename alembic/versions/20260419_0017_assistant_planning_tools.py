"""Extend assistant schema for M6 conversational planning.

Adds `linked_week_id` and `thread_kind` to `assistant_threads` so a thread can
scope to a specific week, and `tool_calls_json` to `assistant_messages` so the
tool-call transcript for each assistant turn can be replayed in the UI.

Revision ID: 20260419_0017
Revises: 20260418_0016
Create Date: 2026-04-19 12:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260419_0017"
down_revision = "20260418_0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("assistant_threads") as batch:
        batch.add_column(
            sa.Column(
                "thread_kind",
                sa.String(length=24),
                nullable=False,
                server_default="chat",
            )
        )
        batch.add_column(
            sa.Column("linked_week_id", sa.String(length=36), nullable=True)
        )
        batch.create_foreign_key(
            "fk_assistant_threads_linked_week_id",
            "weeks",
            ["linked_week_id"],
            ["id"],
            ondelete="SET NULL",
        )
    op.create_index(
        "ix_assistant_threads_linked_week_id",
        "assistant_threads",
        ["linked_week_id"],
        unique=False,
    )

    with op.batch_alter_table("assistant_messages") as batch:
        batch.add_column(
            sa.Column(
                "tool_calls_json",
                sa.Text(),
                nullable=False,
                server_default="[]",
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("assistant_messages") as batch:
        batch.drop_column("tool_calls_json")
    op.drop_index(
        "ix_assistant_threads_linked_week_id",
        table_name="assistant_threads",
    )
    with op.batch_alter_table("assistant_threads") as batch:
        batch.drop_constraint(
            "fk_assistant_threads_linked_week_id", type_="foreignkey"
        )
        batch.drop_column("linked_week_id")
        batch.drop_column("thread_kind")
