"""Flip household_id to NOT NULL on the multi-tenant root tables.

Migration 0027 added ``household_id`` to weeks/recipes/staples/events/
guests as ``nullable=True`` and backfilled it (``SET household_id =
user_id``), with a comment that Phase 2 would flip the column NOT NULL.
That flip never landed, so the DB still permits NULL ``household_id`` on
every multi-tenant root table while the ORM models all declare
``nullable=False`` — a schema/ORM drift and a tenant-scoping gap (a NULL
row silently drops out of every ``household_id == X`` filter).

This migration defensively re-backfills any remaining NULLs from
``user_id`` (no-op on a healthy DB — all live writers + seed set
household_id) then flips each column NOT NULL, making tenant scoping a
schema guarantee rather than an application convention.

Revision ID: 20260530_0043
Revises: 20260522_0042
Create Date: 2026-05-30 12:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260530_0043"
down_revision = "20260522_0042"
branch_labels = None
depends_on = None

# Same set 0027 added household_id to. All still carry user_id, so the
# backfill source is available.
SHARED_TABLES = ("weeks", "recipes", "staples", "events", "guests")


def upgrade() -> None:
    for table in SHARED_TABLES:
        op.execute(  # noqa: S608 — table names are a fixed local constant, not user input
            f"UPDATE {table} SET household_id = user_id WHERE household_id IS NULL"
        )
        # batch_alter_table so the SQLite test harness can apply the
        # nullability change (SQLite has no ALTER COLUMN → Alembic recreates
        # the table). On Postgres (recreate="auto") this emits a plain ALTER.
        with op.batch_alter_table(table) as batch_op:
            batch_op.alter_column(
                "household_id",
                existing_type=sa.String(length=36),
                nullable=False,
            )


def downgrade() -> None:
    for table in SHARED_TABLES:
        with op.batch_alter_table(table) as batch_op:
            batch_op.alter_column(
                "household_id",
                existing_type=sa.String(length=36),
                nullable=True,
            )
