"""Build 95: admin-granted Pro subscriptions.

Two changes to ``subscriptions`` so the admin UI can grant Pro
without an Apple receipt:

- ``apple_original_transaction_id`` becomes nullable. Apple-billed
  rows still carry it; admin-granted rows leave it ``NULL``. The
  existing UNIQUE index keeps working because Postgres treats NULL
  values as distinct.
- New ``admin_note`` column captures the operator's reason ("Beta
  reward", "Refund replacement", etc.) — null for normal Apple
  rows.

Revision ID: 20260512_0040
Revises: 20260511_0039
Create Date: 2026-05-12 12:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260512_0040"
down_revision = "20260511_0039"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # batch_alter_table so the SQLite test harness can apply the nullability
    # change — SQLite has no ALTER COLUMN, so Alembic recreates the table.
    # On Postgres (recreate="auto") this still emits a plain ALTER.
    with op.batch_alter_table("subscriptions") as batch_op:
        batch_op.alter_column(
            "apple_original_transaction_id",
            existing_type=sa.String(length=40),
            nullable=True,
        )
        batch_op.add_column(sa.Column("admin_note", sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("subscriptions") as batch_op:
        batch_op.drop_column("admin_note")
        batch_op.alter_column(
            "apple_original_transaction_id",
            existing_type=sa.String(length=40),
            nullable=False,
        )
