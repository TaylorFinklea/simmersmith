"""Add assigned_guest_id to event_meals so a dish can be flagged as
"Kirsten is bringing it" instead of implying the host is making
everything. Nullable — unassigned means the host is cooking.

Revision ID: 20260424_0020
Revises: 20260424_0019
Create Date: 2026-04-24 15:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260424_0020"
down_revision = "20260424_0019"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("event_meals") as batch:
        batch.add_column(
            sa.Column("assigned_guest_id", sa.String(length=36), nullable=True)
        )
        batch.create_foreign_key(
            "fk_event_meals_assigned_guest_id",
            "guests",
            ["assigned_guest_id"],
            ["id"],
            ondelete="SET NULL",
        )
    op.create_index(
        "ix_event_meals_assigned_guest_id",
        "event_meals",
        ["assigned_guest_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_event_meals_assigned_guest_id", table_name="event_meals")
    with op.batch_alter_table("event_meals") as batch:
        batch.drop_constraint("fk_event_meals_assigned_guest_id", type_="foreignkey")
        batch.drop_column("assigned_guest_id")
