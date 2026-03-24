"""Add nutrition catalog and ingredient nutrition matches.

Revision ID: 20260324_0008
Revises: 20260323_0007
Create Date: 2026-03-24 08:30:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260324_0008"
down_revision = "20260323_0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "nutrition_items",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("reference_amount", sa.Float(), nullable=False, server_default="1.0"),
        sa.Column("reference_unit", sa.String(length=40), nullable=False, server_default="ea"),
        sa.Column("calories", sa.Float(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("normalized_name"),
    )
    op.create_index("ix_nutrition_items_normalized_name", "nutrition_items", ["normalized_name"], unique=False)

    op.create_table(
        "ingredient_nutrition_matches",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("nutrition_item_id", sa.String(length=36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.ForeignKeyConstraint(["nutrition_item_id"], ["nutrition_items.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("normalized_ingredient_name", name="uq_ingredient_nutrition_match_name"),
    )
    op.create_index(
        "ix_ingredient_nutrition_matches_normalized_ingredient_name",
        "ingredient_nutrition_matches",
        ["normalized_ingredient_name"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_ingredient_nutrition_matches_normalized_ingredient_name",
        table_name="ingredient_nutrition_matches",
    )
    op.drop_table("ingredient_nutrition_matches")
    op.drop_index("ix_nutrition_items_normalized_name", table_name="nutrition_items")
    op.drop_table("nutrition_items")
