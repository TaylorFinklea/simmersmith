"""Widen recipe-FK columns to match recipes.id (String(120)).

recipes.id is String(120) and recipe ids are persisted unvalidated
(upsert_recipe stores a client/AI-supplied id up to 120 chars), but the
FK columns week_meal_sides.recipe_id (migration 0032) and
event_meals.recipe_id (migration 0018) were created as String(36).
Linking such a recipe as a side or an event dish overflows the 36-char
column on Postgres → IntegrityError → HTTP 500 (invisible in SQLite
tests, which don't enforce VARCHAR length). Widen both to String(120) to
match the other recipe-FK columns (week_meals.recipe_id is already 120).

Revision ID: 20260530_0045
Revises: 20260530_0044
Create Date: 2026-05-30 13:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260530_0045"
down_revision = "20260530_0044"
branch_labels = None
depends_on = None


def upgrade() -> None:
    for table in ("week_meal_sides", "event_meals"):
        with op.batch_alter_table(table) as batch_op:
            batch_op.alter_column(
                "recipe_id",
                existing_type=sa.String(length=36),
                type_=sa.String(length=120),
                existing_nullable=True,
            )


def downgrade() -> None:
    for table in ("week_meal_sides", "event_meals"):
        with op.batch_alter_table(table) as batch_op:
            batch_op.alter_column(
                "recipe_id",
                existing_type=sa.String(length=120),
                type_=sa.String(length=36),
                existing_nullable=True,
            )
