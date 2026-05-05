"""M28: pantry extension on staples.

`Staple` rows already filter from grocery aggregation — they're
"things we always have, don't add to the list because of meals."
M28 promotes them to a full pantry concept: typical purchase
quantity (informational, e.g. "50 lb bag of flour"), recurring
auto-add to weekly grocery (e.g. "5 dozen eggs each week"), and a
cadence + last-applied timestamp so biweekly / monthly recurrings
don't double-fire.

Schema delta on `staples`:
- `typical_quantity FLOAT NULL`
- `typical_unit     VARCHAR(40) NOT NULL DEFAULT ''`
- `recurring_quantity FLOAT NULL`
- `recurring_unit     VARCHAR(40) NOT NULL DEFAULT ''`
- `recurring_cadence  VARCHAR(24) NOT NULL DEFAULT 'none'`
  (one of: 'none', 'weekly', 'biweekly', 'monthly')
- `category           VARCHAR(120) NOT NULL DEFAULT ''`
- `last_applied_at    TIMESTAMPTZ NULL` — when the recurring fold-
  in last added this row to a week's grocery list. Used to
  rate-limit biweekly/monthly cadences.

Backfill: existing rows are pure staples (no recurring), so
`recurring_cadence='none'` and other fields are zero/empty.

Revision ID: 20260505_0034
Revises: 20260505_0033
Create Date: 2026-05-05 10:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260505_0034"
down_revision = "20260505_0033"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("staples", sa.Column("typical_quantity", sa.Float(), nullable=True))
    op.add_column(
        "staples",
        sa.Column("typical_unit", sa.String(40), nullable=False, server_default=""),
    )
    op.add_column("staples", sa.Column("recurring_quantity", sa.Float(), nullable=True))
    op.add_column(
        "staples",
        sa.Column("recurring_unit", sa.String(40), nullable=False, server_default=""),
    )
    op.add_column(
        "staples",
        sa.Column("recurring_cadence", sa.String(24), nullable=False, server_default="none"),
    )
    op.add_column(
        "staples",
        sa.Column("category", sa.String(120), nullable=False, server_default=""),
    )
    op.add_column(
        "staples",
        sa.Column("last_applied_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("staples", "last_applied_at")
    op.drop_column("staples", "category")
    op.drop_column("staples", "recurring_cadence")
    op.drop_column("staples", "recurring_unit")
    op.drop_column("staples", "recurring_quantity")
    op.drop_column("staples", "typical_unit")
    op.drop_column("staples", "typical_quantity")
