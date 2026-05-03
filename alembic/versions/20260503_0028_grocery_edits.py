"""M22 Phase 1: grocery list mutability fields.

Adds the columns needed for user edits and household-shared check
state on `grocery_items`, plus the per-event auto-merge toggle on
`events`. Pure additive migration — every column is nullable or has
a server default so existing rows survive the alter and existing
queries (which don't reference the new columns) keep working.

Smart-merge regeneration of the grocery list reads these columns to
decide whether an existing row was user-edited (and must be
preserved across meal mutations) or auto-generated (and may be
overwritten/deleted).

Revision ID: 20260503_0028
Revises: 20260501_0027
Create Date: 2026-05-03 00:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260503_0028"
down_revision = "20260501_0027"
branch_labels = None
depends_on = None


GROCERY_NEW_COLUMNS: tuple[tuple[str, sa.Column], ...] = (
    ("is_user_added", sa.Column(
        "is_user_added", sa.Boolean(), nullable=False, server_default=sa.false()
    )),
    ("is_user_removed", sa.Column(
        "is_user_removed", sa.Boolean(), nullable=False, server_default=sa.false()
    )),
    ("quantity_override", sa.Column(
        "quantity_override", sa.Float(), nullable=True
    )),
    ("unit_override", sa.Column(
        "unit_override", sa.String(40), nullable=True
    )),
    ("notes_override", sa.Column(
        "notes_override", sa.Text(), nullable=True
    )),
    ("is_checked", sa.Column(
        "is_checked", sa.Boolean(), nullable=False, server_default=sa.false()
    )),
    ("checked_at", sa.Column(
        "checked_at", sa.DateTime(timezone=True), nullable=True
    )),
    ("checked_by_user_id", sa.Column(
        "checked_by_user_id", sa.String(36), nullable=True
    )),
)


def upgrade() -> None:
    for _, column in GROCERY_NEW_COLUMNS:
        op.add_column("grocery_items", column)

    op.add_column(
        "events",
        sa.Column(
            "auto_merge_grocery",
            sa.Boolean(),
            nullable=False,
            server_default=sa.true(),
        ),
    )


def downgrade() -> None:
    op.drop_column("events", "auto_merge_grocery")
    for name, _ in reversed(GROCERY_NEW_COLUMNS):
        op.drop_column("grocery_items", name)
