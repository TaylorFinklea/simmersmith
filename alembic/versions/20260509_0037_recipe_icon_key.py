"""Build 85: per-recipe icon key.

Adds ``icon_key VARCHAR(40) NOT NULL DEFAULT ''`` to ``recipes`` so the
hand-drawn meal glyph picked by the user (or auto-detected by the iOS
client) survives across devices via household sync. Empty string means
"no explicit pick — let the client auto-detect from name/mealType".

The legal value space is owned by the iOS client (the ``MealIcon``
enum). Server treats the column as opaque text so we can grow the
catalog without coordinating migrations.

Revision ID: 20260509_0037
Revises: 20260506_0036
Create Date: 2026-05-09 22:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260509_0037"
down_revision = "20260506_0036"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "recipes",
        sa.Column(
            "icon_key",
            sa.String(length=40),
            server_default="",
            nullable=False,
        ),
    )


def downgrade() -> None:
    op.drop_column("recipes", "icon_key")
