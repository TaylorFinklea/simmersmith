"""Build 87: per-item grocery store label.

Adds ``store_label VARCHAR(40) NOT NULL DEFAULT ''`` to
``grocery_items`` so each grocery row can carry the store the user
plans to buy it from (Kroger, Aldi, etc.). Empty string means "no
preference / unset"; the iOS Reminders sync uses the field to annotate
the EKReminder when present.

Free-text on purpose so users can write whatever — the iOS client
suggests the existing store-section labels from the household profile
but does not constrain to them.

Revision ID: 20260510_0038
Revises: 20260509_0037
Create Date: 2026-05-10 19:30:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260510_0038"
down_revision = "20260509_0037"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "grocery_items",
        sa.Column(
            "store_label",
            sa.String(length=40),
            server_default="",
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column("grocery_items", "store_label")
