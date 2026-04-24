"""Event Plans — guests, events, event meals, event grocery items.

Adds a parallel planning surface for one-off events (holidays, birthdays,
dinner parties) alongside the recurring week. Guests are named, reusable
entities with stored dietary constraints; events join guests via the
`event_attendees` M2M table with optional `plus_ones` so one Guest row
can represent a family for a specific event without needing per-member
data.

Grocery items live separately from `grocery_items` until the user chooses
to merge an event into a week — at which point `merged_into_week_id`
records the bridge for traceability.

Revision ID: 20260424_0018
Revises: 20260419_0017
Create Date: 2026-04-24 12:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260424_0018"
down_revision = "20260419_0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "guests",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("user_id", sa.String(length=36), nullable=False, index=True),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("relationship", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("dietary_notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("allergies", sa.Text(), nullable=False, server_default=""),
        sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_guests_user_id_name", "guests", ["user_id", "name"])

    op.create_table(
        "events",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("user_id", sa.String(length=36), nullable=False, index=True),
        sa.Column("name", sa.String(length=200), nullable=False),
        sa.Column("event_date", sa.Date(), nullable=True),
        sa.Column("occasion", sa.String(length=64), nullable=False, server_default="other"),
        sa.Column("attendee_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("status", sa.String(length=24), nullable=False, server_default="draft"),
        sa.Column("linked_week_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["linked_week_id"],
            ["weeks.id"],
            ondelete="SET NULL",
            name="fk_events_linked_week_id",
        ),
    )
    op.create_index("ix_events_user_id_event_date", "events", ["user_id", "event_date"])
    op.create_index("ix_events_linked_week_id", "events", ["linked_week_id"])

    op.create_table(
        "event_attendees",
        sa.Column("event_id", sa.String(length=36), nullable=False),
        sa.Column("guest_id", sa.String(length=36), nullable=False),
        sa.Column("plus_ones", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["event_id"], ["events.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["guest_id"], ["guests.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("event_id", "guest_id"),
    )

    op.create_table(
        "event_meals",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("event_id", sa.String(length=36), nullable=False),
        sa.Column("role", sa.String(length=32), nullable=False, server_default="main"),
        sa.Column("recipe_id", sa.String(length=36), nullable=True),
        sa.Column("recipe_name", sa.String(length=255), nullable=False),
        sa.Column("servings", sa.Float(), nullable=True),
        sa.Column("scale_multiplier", sa.Float(), nullable=False, server_default="1.0"),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("ai_generated", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("approved", sa.Boolean(), nullable=False, server_default=sa.false()),
        # JSON list of guest_ids the AI judged this dish to work for.
        # Defense-in-depth + lets the UI show per-guest coverage.
        sa.Column("constraint_coverage", sa.Text(), nullable=False, server_default="[]"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["event_id"], ["events.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="SET NULL"),
    )
    op.create_index("ix_event_meals_event_id", "event_meals", ["event_id"])

    op.create_table(
        "event_meal_ingredients",
        sa.Column("id", sa.String(length=140), primary_key=True),
        sa.Column("event_meal_id", sa.String(length=36), nullable=False),
        sa.Column("base_ingredient_id", sa.String(length=36), nullable=True, index=True),
        sa.Column("ingredient_variation_id", sa.String(length=36), nullable=True, index=True),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False, index=True),
        sa.Column("quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("prep", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("category", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("resolution_status", sa.String(length=24), nullable=False, server_default="unresolved"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["event_meal_id"], ["event_meals.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["base_ingredient_id"], ["base_ingredients.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["ingredient_variation_id"], ["ingredient_variations.id"], ondelete="SET NULL"),
    )

    op.create_table(
        "event_grocery_items",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("event_id", sa.String(length=36), nullable=False),
        sa.Column("base_ingredient_id", sa.String(length=36), nullable=True, index=True),
        sa.Column("ingredient_variation_id", sa.String(length=36), nullable=True, index=True),
        sa.Column("ingredient_name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False, index=True),
        sa.Column("total_quantity", sa.Float(), nullable=True),
        sa.Column("unit", sa.String(length=40), nullable=False, server_default=""),
        sa.Column("quantity_text", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("category", sa.String(length=120), nullable=False, server_default=""),
        sa.Column("source_meals", sa.Text(), nullable=False, server_default=""),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("review_flag", sa.Text(), nullable=False, server_default=""),
        sa.Column("resolution_status", sa.String(length=24), nullable=False, server_default="unresolved"),
        # Merge bridge — when the user merges event groceries into a week
        # these two columns record which row the quantity was rolled into.
        sa.Column("merged_into_week_id", sa.String(length=36), nullable=True),
        sa.Column("merged_into_grocery_item_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["event_id"], ["events.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["base_ingredient_id"], ["base_ingredients.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["ingredient_variation_id"], ["ingredient_variations.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["merged_into_week_id"], ["weeks.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["merged_into_grocery_item_id"], ["grocery_items.id"], ondelete="SET NULL"),
    )
    op.create_index("ix_event_grocery_items_event_id", "event_grocery_items", ["event_id"])


def downgrade() -> None:
    op.drop_index("ix_event_grocery_items_event_id", table_name="event_grocery_items")
    op.drop_table("event_grocery_items")
    op.drop_table("event_meal_ingredients")
    op.drop_index("ix_event_meals_event_id", table_name="event_meals")
    op.drop_table("event_meals")
    op.drop_table("event_attendees")
    op.drop_index("ix_events_linked_week_id", table_name="events")
    op.drop_index("ix_events_user_id_event_date", table_name="events")
    op.drop_table("events")
    op.drop_index("ix_guests_user_id_name", table_name="guests")
    op.drop_table("guests")
