"""M26 Phase 2: sides on a meal.

`WeekMealSide` lets a meal carry zero-to-many sides. Each side is a
named companion dish with an optional recipe link — when linked, the
side's ingredients flow through grocery aggregation just like the
parent meal's ingredients (scaled by the parent's `scale_multiplier`).
Sides without a recipe link are informational only.

Schema:
    week_meal_sides (
        id, week_meal_id, recipe_id?, name, notes, sort_order,
        created_at, updated_at
    )
    INDEX ix_week_meal_sides_week_meal_id

Cascade: deleting a `week_meals` row deletes its sides; nulling
`recipe_id` (recipe deleted) leaves the side rooted on its meal so the
user can relink or convert it to a freeform name.

Revision ID: 20260505_0032
Revises: 20260504_0031
Create Date: 2026-05-05 09:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260505_0032"
down_revision = "20260504_0031"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "week_meal_sides",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "week_meal_id",
            sa.String(36),
            sa.ForeignKey("week_meals.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "recipe_id",
            sa.String(36),
            sa.ForeignKey("recipes.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_week_meal_sides_week_meal_id",
        "week_meal_sides",
        ["week_meal_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_week_meal_sides_week_meal_id", table_name="week_meal_sides")
    op.drop_table("week_meal_sides")
