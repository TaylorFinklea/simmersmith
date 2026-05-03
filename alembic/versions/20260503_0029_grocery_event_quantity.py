"""M22.2: track event-merged quantity separately on grocery_items.

Splits a `GroceryItem`'s effective quantity into two storage slots:
- `total_quantity` — the auto-aggregated portion from the week's meals.
- `event_quantity` — the portion contributed by `merge_event_into_week`
  for events whose `auto_merge_grocery=True` falls within this week.

Smart-merge regeneration can now refresh `total_quantity` without
disturbing the event contribution. iOS sums the two for display.

Pure additive: existing rows get `event_quantity = NULL` (treated as
zero on display so behavior unchanged for legacy data). Previously-
merged event additions stay baked into `total_quantity` on those
rows; the next `unmerge` + `merge` cycle will redistribute correctly.

Revision ID: 20260503_0029
Revises: 20260503_0028
Create Date: 2026-05-03 12:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260503_0029"
down_revision = "20260503_0028"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "grocery_items",
        sa.Column("event_quantity", sa.Float(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("grocery_items", "event_quantity")
