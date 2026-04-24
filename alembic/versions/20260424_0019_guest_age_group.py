"""Add age_group to guests so the AI knows whether an attendee is a
baby/toddler/child/teen/adult when sizing portions and choosing safe
dishes (e.g. no whole grapes for toddlers, no raw fish for infants).

Default is "adult" — existing rows get back-filled via the server_default.

Revision ID: 20260424_0019
Revises: 20260424_0018
Create Date: 2026-04-24 14:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260424_0019"
down_revision = "20260424_0018"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("guests") as batch:
        batch.add_column(
            sa.Column(
                "age_group",
                sa.String(length=24),
                nullable=False,
                server_default="adult",
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("guests") as batch:
        batch.drop_column("age_group")
