"""Add week staging history, feedback, and export runs.

Revision ID: 20260316_0003
Revises: 20260313_0002
Create Date: 2026-03-16 00:03:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260316_0003"
down_revision = "20260313_0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("weeks", sa.Column("ready_for_ai_at", sa.DateTime(timezone=True), nullable=True))
    op.execute("UPDATE weeks SET status = 'staging' WHERE status = 'draft'")

    op.create_table(
        "week_change_batches",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("actor_type", sa.String(length=40), nullable=False),
        sa.Column("actor_label", sa.String(length=80), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "week_change_events",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("batch_id", sa.String(length=36), nullable=False),
        sa.Column("entity_type", sa.String(length=40), nullable=False),
        sa.Column("entity_id", sa.String(length=36), nullable=False),
        sa.Column("field_name", sa.String(length=80), nullable=False),
        sa.Column("before_value", sa.Text(), nullable=False),
        sa.Column("after_value", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["batch_id"], ["week_change_batches.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "feedback_entries",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("meal_id", sa.String(length=36), nullable=True),
        sa.Column("grocery_item_id", sa.String(length=36), nullable=True),
        sa.Column("target_type", sa.String(length=40), nullable=False),
        sa.Column("target_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("retailer", sa.String(length=40), nullable=False),
        sa.Column("sentiment", sa.Integer(), nullable=False),
        sa.Column("reason_codes", sa.Text(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("source", sa.String(length=40), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["grocery_item_id"], ["grocery_items.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["meal_id"], ["week_meals.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_feedback_entries_normalized_name"), "feedback_entries", ["normalized_name"], unique=False)

    op.create_table(
        "export_runs",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("destination", sa.String(length=40), nullable=False),
        sa.Column("export_type", sa.String(length=40), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("item_count", sa.Integer(), nullable=False),
        sa.Column("error", sa.Text(), nullable=False),
        sa.Column("external_ref", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "export_items",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("export_run_id", sa.String(length=36), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("list_name", sa.String(length=120), nullable=False),
        sa.Column("title", sa.String(length=255), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("metadata_json", sa.Text(), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.ForeignKeyConstraint(["export_run_id"], ["export_runs.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    op.drop_table("export_items")
    op.drop_table("export_runs")
    op.drop_index(op.f("ix_feedback_entries_normalized_name"), table_name="feedback_entries")
    op.drop_table("feedback_entries")
    op.drop_table("week_change_events")
    op.drop_table("week_change_batches")
    op.drop_column("weeks", "ready_for_ai_at")
