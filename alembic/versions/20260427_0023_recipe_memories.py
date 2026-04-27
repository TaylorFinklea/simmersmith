"""Add recipe_memories table for the per-cook memories log (M15).

One row per memory entry. Phase 1 ships text-only; Phase 2 will
add `image_bytes` + `mime_type` columns. The legacy `recipes.memories`
text blob is migrated into a single seed row per recipe via the
data-migration step below so users don't lose history.

Revision ID: 20260427_0023
Revises: 20260426_0022
Create Date: 2026-04-27 12:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260427_0023"
down_revision = "20260426_0022"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "recipe_memories",
        sa.Column("id", sa.String(140), primary_key=True),
        sa.Column("recipe_id", sa.String(120), nullable=False, index=True),
        sa.Column("body", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.ForeignKeyConstraint(
            ["recipe_id"],
            ["recipes.id"],
            ondelete="CASCADE",
            name="fk_recipe_memories_recipe_id",
        ),
    )

    # Backfill: copy each non-empty `recipes.memories` blob into a
    # single seed memory row so existing data stays visible after
    # the iOS UI cuts over to the log view. The id is built from
    # `recipe_id` + a "-legacy" suffix so the backfill is idempotent
    # if anyone reruns it (a second run would conflict on the PK).
    op.execute(
        """
        INSERT INTO recipe_memories (id, recipe_id, body, created_at)
        SELECT id || '-legacy', id, memories, created_at
        FROM recipes
        WHERE memories IS NOT NULL
          AND TRIM(memories) <> ''
        """
    )


def downgrade() -> None:
    op.drop_table("recipe_memories")
