"""M24: ranked ingredient preferences (primary / secondary / etc.).

Replaces the implicit single-preference-per-base model with a ranked
list. `rank=1` is the primary brand/variation; `rank=2` is the
secondary fallback used when the primary is unavailable; arbitrary
higher ranks are supported but the UI only surfaces 1-3 today.

Schema delta:
- Add `rank` INTEGER NOT NULL DEFAULT 1.
- Drop the old UNIQUE (user_id, base_ingredient_id).
- Add UNIQUE (user_id, base_ingredient_id, rank) so each rank slot
  is distinct per user/base, but multiple ranks can coexist.

Backfill: every existing preference row gets `rank=1` via the
DEFAULT, no data movement required.

Revision ID: 20260504_0030
Revises: 20260503_0029
Create Date: 2026-05-04 00:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260504_0030"
down_revision = "20260503_0029"
branch_labels = None
depends_on = None


OLD_UNIQUE = "uq_ingredient_preferences_user_base"
NEW_UNIQUE = "uq_ingredient_preferences_user_base_rank"


def upgrade() -> None:
    op.add_column(
        "ingredient_preferences",
        sa.Column("rank", sa.Integer(), nullable=False, server_default="1"),
    )
    # Postgres + SQLite both honor DROP CONSTRAINT through batch_alter_table;
    # the explicit `with_alter` keeps the SQLite path correct (it has to
    # rebuild the table to drop a UNIQUE).
    with op.batch_alter_table("ingredient_preferences") as batch:
        batch.drop_constraint(OLD_UNIQUE, type_="unique")
        batch.create_unique_constraint(
            NEW_UNIQUE,
            ["user_id", "base_ingredient_id", "rank"],
        )


def downgrade() -> None:
    with op.batch_alter_table("ingredient_preferences") as batch:
        batch.drop_constraint(NEW_UNIQUE, type_="unique")
        batch.create_unique_constraint(
            OLD_UNIQUE,
            ["user_id", "base_ingredient_id"],
        )
    op.drop_column("ingredient_preferences", "rank")
