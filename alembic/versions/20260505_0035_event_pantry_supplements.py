"""M28 phase 2: event pantry supplements.

When an event needs extra of a pantry item beyond normal household
stock (e.g. "we usually keep 5 dozen eggs but this party needs
100"), the user can attach a supplement record to the event. The
supplement flows through the existing event-grocery → week-grocery
merge path as `event_quantity` so the user sees a clear "+100 for
the party" attribution alongside the recurring restock.

Schema:
    event_pantry_supplements (
        id, event_id, pantry_item_id, quantity, unit, notes,
        created_at, updated_at
    )
    UNIQUE (event_id, pantry_item_id)
    INDEX ix_event_pantry_supplements_event_id

Cascade:
- Deleting an event removes its supplements (CASCADE).
- Deleting a pantry item removes its supplements (CASCADE) — the
  alternative (NULL the FK) would orphan supplements that the user
  can no longer edit.

Revision ID: 20260505_0035
Revises: 20260505_0034
Create Date: 2026-05-05 11:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260505_0035"
down_revision = "20260505_0034"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "event_pantry_supplements",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "event_id",
            sa.String(36),
            sa.ForeignKey("events.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "pantry_item_id",
            sa.String(36),
            sa.ForeignKey("staples.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit", sa.String(40), nullable=False, server_default=""),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint(
            "event_id", "pantry_item_id", name="uq_event_pantry_supplements_event_pantry"
        ),
    )
    op.create_index(
        "ix_event_pantry_supplements_event_id",
        "event_pantry_supplements",
        ["event_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_event_pantry_supplements_event_id",
        table_name="event_pantry_supplements",
    )
    op.drop_table("event_pantry_supplements")
