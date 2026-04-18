"""Add macro columns to catalog and a per-user dietary_goals table.

- BaseIngredient/IngredientVariation gain nullable protein_g / carbs_g / fat_g /
  fiber_g (all grams, per the row's existing nutrition_reference_amount+unit).
- New `dietary_goals` table stores per-user daily targets for the AI planner.

Revision ID: 20260418_0015
Revises: 20260410_0014
Create Date: 2026-04-18 12:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260418_0015"
down_revision = "20260410_0014"
branch_labels = None
depends_on = None


MACRO_COLUMNS = ("protein_g", "carbs_g", "fat_g", "fiber_g")


def _add_macro_columns(table: str) -> None:
    for col in MACRO_COLUMNS:
        op.add_column(table, sa.Column(col, sa.Float(), nullable=True))


def _drop_macro_columns(table: str) -> None:
    for col in MACRO_COLUMNS:
        op.drop_column(table, col)


def upgrade() -> None:
    _add_macro_columns("base_ingredients")
    _add_macro_columns("ingredient_variations")

    op.create_table(
        "dietary_goals",
        sa.Column("user_id", sa.String(length=36), nullable=False),
        sa.Column("goal_type", sa.String(length=24), nullable=False, server_default="maintain"),
        sa.Column("daily_calories", sa.Integer(), nullable=False),
        sa.Column("protein_g", sa.Integer(), nullable=False),
        sa.Column("carbs_g", sa.Integer(), nullable=False),
        sa.Column("fat_g", sa.Integer(), nullable=False),
        sa.Column("fiber_g", sa.Integer(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
        sa.PrimaryKeyConstraint("user_id"),
    )


def downgrade() -> None:
    op.drop_table("dietary_goals")
    _drop_macro_columns("ingredient_variations")
    _drop_macro_columns("base_ingredients")
