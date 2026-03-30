"""Add canonical ingredient catalog and resolution links.

Revision ID: 20260330_0012
Revises: 20260329_0011
Create Date: 2026-03-30 12:30:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260330_0012"
down_revision = "20260329_0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "base_ingredients",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("category", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("default_unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("nutrition_reference_amount", sa.Float(), nullable=True),
        sa.Column("nutrition_reference_unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("calories", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("normalized_name"),
    )
    op.create_index("ix_base_ingredients_normalized_name", "base_ingredients", ["normalized_name"])

    op.create_table(
        "ingredient_variations",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("base_ingredient_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("brand", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("package_size_amount", sa.Float(), nullable=True),
        sa.Column("package_size_unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("count_per_package", sa.Float(), nullable=True),
        sa.Column("product_url", sa.Text(), nullable=False, server_default=""),
        sa.Column("retailer_hint", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("nutrition_reference_amount", sa.Float(), nullable=True),
        sa.Column("nutrition_reference_unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("calories", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["base_ingredient_id"], ["base_ingredients.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("base_ingredient_id", "normalized_name", name="uq_variation_base_name"),
    )
    op.create_index("ix_ingredient_variations_base_ingredient_id", "ingredient_variations", ["base_ingredient_id"])
    op.create_index("ix_ingredient_variations_normalized_name", "ingredient_variations", ["normalized_name"])

    op.create_table(
        "ingredient_preferences",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("base_ingredient_id", sa.String(length=36), nullable=False),
        sa.Column("preferred_variation_id", sa.String(length=36), nullable=True),
        sa.Column("preferred_brand", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("choice_mode", sa.String(length=32), nullable=False, server_default="preferred"),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["base_ingredient_id"], ["base_ingredients.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["preferred_variation_id"], ["ingredient_variations.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("base_ingredient_id", name="uq_ingredient_preference_base"),
    )
    op.create_index("ix_ingredient_preferences_base_ingredient_id", "ingredient_preferences", ["base_ingredient_id"])
    op.create_index(
        "ix_ingredient_preferences_preferred_variation_id",
        "ingredient_preferences",
        ["preferred_variation_id"],
    )

    for table_name in ("recipe_ingredients", "week_meal_ingredients", "grocery_items"):
        with op.batch_alter_table(table_name) as batch_op:
            batch_op.add_column(sa.Column("base_ingredient_id", sa.String(length=36), nullable=True))
            batch_op.add_column(sa.Column("ingredient_variation_id", sa.String(length=36), nullable=True))
            batch_op.add_column(
                sa.Column("resolution_status", sa.String(length=24), nullable=False, server_default="unresolved")
            )
            batch_op.create_index(f"ix_{table_name}_base_ingredient_id", ["base_ingredient_id"])
            batch_op.create_index(f"ix_{table_name}_ingredient_variation_id", ["ingredient_variation_id"])
            batch_op.create_foreign_key(
                f"fk_{table_name}_base_ingredient_id",
                "base_ingredients",
                ["base_ingredient_id"],
                ["id"],
                ondelete="SET NULL",
            )
            batch_op.create_foreign_key(
                f"fk_{table_name}_ingredient_variation_id",
                "ingredient_variations",
                ["ingredient_variation_id"],
                ["id"],
                ondelete="SET NULL",
            )


def downgrade() -> None:
    for table_name in ("grocery_items", "week_meal_ingredients", "recipe_ingredients"):
        with op.batch_alter_table(table_name) as batch_op:
            batch_op.drop_constraint(f"fk_{table_name}_ingredient_variation_id", type_="foreignkey")
            batch_op.drop_constraint(f"fk_{table_name}_base_ingredient_id", type_="foreignkey")
            batch_op.drop_index(f"ix_{table_name}_ingredient_variation_id")
            batch_op.drop_index(f"ix_{table_name}_base_ingredient_id")
            batch_op.drop_column("resolution_status")
            batch_op.drop_column("ingredient_variation_id")
            batch_op.drop_column("base_ingredient_id")

    op.drop_index("ix_ingredient_preferences_preferred_variation_id", table_name="ingredient_preferences")
    op.drop_index("ix_ingredient_preferences_base_ingredient_id", table_name="ingredient_preferences")
    op.drop_table("ingredient_preferences")

    op.drop_index("ix_ingredient_variations_normalized_name", table_name="ingredient_variations")
    op.drop_index("ix_ingredient_variations_base_ingredient_id", table_name="ingredient_variations")
    op.drop_table("ingredient_variations")

    op.drop_index("ix_base_ingredients_normalized_name", table_name="base_ingredients")
    op.drop_table("base_ingredients")
