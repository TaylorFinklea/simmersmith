"""Initial simmersmith schema.

Revision ID: 20260312_0001
Revises:
Create Date: 2026-03-12 00:01:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260312_0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "profile_settings",
        sa.Column("key", sa.String(length=80), nullable=False),
        sa.Column("value", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("key"),
    )
    op.create_table(
        "staples",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("staple_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_staples_normalized_name"), "staples", ["normalized_name"], unique=True)
    op.create_table(
        "recipes",
        sa.Column("id", sa.String(length=120), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("meal_type", sa.String(length=40), nullable=False),
        sa.Column("cuisine", sa.String(length=120), nullable=False),
        sa.Column("servings", sa.Float(), nullable=True),
        sa.Column("prep_minutes", sa.Integer(), nullable=True),
        sa.Column("cook_minutes", sa.Integer(), nullable=True),
        sa.Column("tags", sa.Text(), nullable=False),
        sa.Column("instructions_summary", sa.Text(), nullable=False),
        sa.Column("favorite", sa.Boolean(), nullable=False),
        sa.Column("source", sa.String(length=40), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("last_used", sa.Date(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "weeks",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_start", sa.Date(), nullable=False),
        sa.Column("week_end", sa.Date(), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("approved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("priced_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_weeks_week_start"), "weeks", ["week_start"], unique=True)
    op.create_table(
        "ai_runs",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=True),
        sa.Column("run_type", sa.String(length=32), nullable=False),
        sa.Column("model", sa.String(length=120), nullable=False),
        sa.Column("prompt", sa.Text(), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("request_payload", sa.Text(), nullable=False),
        sa.Column("response_payload", sa.Text(), nullable=False),
        sa.Column("error", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "pricing_runs",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("requested_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("item_count", sa.Integer(), nullable=False),
        sa.Column("totals_json", sa.Text(), nullable=False),
        sa.Column("error", sa.Text(), nullable=False),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "recipe_ingredients",
        sa.Column("id", sa.String(length=140), nullable=False),
        sa.Column("recipe_id", sa.String(length=120), nullable=False),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=40), nullable=False),
        sa.Column("prep", sa.String(length=120), nullable=False),
        sa.Column("category", sa.String(length=120), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_recipe_ingredients_normalized_name"), "recipe_ingredients", ["normalized_name"], unique=False)
    op.create_table(
        "week_meals",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("day_name", sa.String(length=20), nullable=False),
        sa.Column("meal_date", sa.Date(), nullable=False),
        sa.Column("slot", sa.String(length=20), nullable=False),
        sa.Column("recipe_id", sa.String(length=120), nullable=True),
        sa.Column("recipe_name", sa.String(length=255), nullable=False),
        sa.Column("servings", sa.Float(), nullable=True),
        sa.Column("source", sa.String(length=40), nullable=False),
        sa.Column("approved", sa.Boolean(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("ai_generated", sa.Boolean(), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("week_id", "day_name", "slot", name="uq_week_day_slot"),
    )
    op.create_table(
        "grocery_items",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("week_id", sa.String(length=36), nullable=False),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("total_quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=40), nullable=False),
        sa.Column("quantity_text", sa.String(length=120), nullable=False),
        sa.Column("category", sa.String(length=120), nullable=False),
        sa.Column("source_meals", sa.Text(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("review_flag", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["week_id"], ["weeks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_grocery_items_normalized_name"), "grocery_items", ["normalized_name"], unique=False)
    op.create_table(
        "week_meal_ingredients",
        sa.Column("id", sa.String(length=140), nullable=False),
        sa.Column("week_meal_id", sa.String(length=36), nullable=False),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=40), nullable=False),
        sa.Column("prep", sa.String(length=120), nullable=False),
        sa.Column("category", sa.String(length=120), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["week_meal_id"], ["week_meals.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_week_meal_ingredients_normalized_name"),
        "week_meal_ingredients",
        ["normalized_name"],
        unique=False,
    )
    op.create_table(
        "retailer_prices",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("grocery_item_id", sa.String(length=36), nullable=False),
        sa.Column("retailer", sa.String(length=40), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("store_name", sa.String(length=255), nullable=False),
        sa.Column("product_name", sa.String(length=255), nullable=False),
        sa.Column("package_size", sa.String(length=120), nullable=False),
        sa.Column("unit_price", sa.Float(), nullable=True),
        sa.Column("line_price", sa.Float(), nullable=True),
        sa.Column("product_url", sa.Text(), nullable=False),
        sa.Column("availability", sa.String(length=255), nullable=False),
        sa.Column("candidate_score", sa.Float(), nullable=True),
        sa.Column("review_note", sa.Text(), nullable=False),
        sa.Column("raw_query", sa.String(length=255), nullable=False),
        sa.Column("scraped_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["grocery_item_id"], ["grocery_items.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("grocery_item_id", "retailer", name="uq_item_retailer"),
    )


def downgrade() -> None:
    op.drop_table("retailer_prices")
    op.drop_index(op.f("ix_week_meal_ingredients_normalized_name"), table_name="week_meal_ingredients")
    op.drop_table("week_meal_ingredients")
    op.drop_index(op.f("ix_grocery_items_normalized_name"), table_name="grocery_items")
    op.drop_table("grocery_items")
    op.drop_table("week_meals")
    op.drop_index(op.f("ix_recipe_ingredients_normalized_name"), table_name="recipe_ingredients")
    op.drop_table("recipe_ingredients")
    op.drop_table("pricing_runs")
    op.drop_table("ai_runs")
    op.drop_index(op.f("ix_weeks_week_start"), table_name="weeks")
    op.drop_table("weeks")
    op.drop_table("recipes")
    op.drop_index(op.f("ix_staples_normalized_name"), table_name="staples")
    op.drop_table("staples")
    op.drop_table("profile_settings")
