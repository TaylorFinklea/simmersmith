"""Build 57: freezer kind on staples.

Adds `frozen_at TIMESTAMPTZ NULL` to `staples`. NULL means a regular
pantry item; non-NULL means the row is a freezer item placed at that
timestamp. Drives the build-57 "Use Soon" filter (items frozen ≥30d)
and the FIFO Freezer view in the iOS pantry list.

No backfill — every existing pantry row is implicitly a regular
(non-frozen) item.

Revision ID: 20260506_0036
Revises: 20260505_0035
Create Date: 2026-05-06 09:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260506_0036"
down_revision = "20260505_0035"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "staples",
        sa.Column("frozen_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("staples", "frozen_at")
