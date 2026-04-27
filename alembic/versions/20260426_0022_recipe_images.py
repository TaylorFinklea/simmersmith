"""Add recipe_images table for AI-generated header images.

One row per recipe (PK = recipe_id, FK with ON DELETE CASCADE). Bytes
live in a separate table so list/detail recipe queries don't pull
~1 MB of binary per row. Served by `GET /api/recipes/{id}/image`.

Revision ID: 20260426_0022
Revises: 20260425_0021
Create Date: 2026-04-26 16:30:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260426_0022"
down_revision = "20260425_0021"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "recipe_images",
        sa.Column("recipe_id", sa.String(120), nullable=False),
        sa.Column("image_bytes", sa.LargeBinary(), nullable=False),
        sa.Column("mime_type", sa.String(64), nullable=False, server_default="image/png"),
        sa.Column("prompt", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "generated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.PrimaryKeyConstraint("recipe_id", name="pk_recipe_images"),
        sa.ForeignKeyConstraint(
            ["recipe_id"],
            ["recipes.id"],
            ondelete="CASCADE",
            name="fk_recipe_images_recipe_id",
        ),
    )


def downgrade() -> None:
    op.drop_table("recipe_images")
