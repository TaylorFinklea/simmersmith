"""Add managed recipe lists, nested steps, and meal scaling.

Revision ID: 20260323_0007
Revises: 20260323_0006
Create Date: 2026-03-23 18:30:00
"""
from __future__ import annotations

import json
import re

from alembic import op
import sqlalchemy as sa


revision = "20260323_0007"
down_revision = "20260323_0006"
branch_labels = None
depends_on = None


DEFAULTS: dict[str, list[str]] = {
    "cuisine": [
        "American",
        "Chinese",
        "Indian",
        "Italian",
        "Japanese",
        "Korean",
        "Mediterranean",
        "Mexican",
        "Thai",
        "Vietnamese",
    ],
    "tag": [
        "Family favorite",
        "High protein",
        "Kid friendly",
        "Low carb",
        "Meal prep",
        "Quick",
        "Vegetarian",
        "Weeknight",
    ],
    "unit": ["bag", "bunch", "can", "clove", "cup", "ea", "fl oz", "gal", "lb", "oz", "pkg", "slice", "tbsp", "tsp"],
}


def normalize_name(value: str) -> str:
    cleaned = value.lower().strip().replace("&", " and ")
    cleaned = re.sub(r"[^a-z0-9\s]", " ", cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def extract_tags(value: str) -> list[str]:
    text = (value or "").strip()
    if not text:
        return []
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = None
    if isinstance(parsed, list):
        raw_items = parsed
    else:
        raw_items = re.split(r"[,;\n]+", text)
    tags: list[str] = []
    seen: set[str] = set()
    for item in raw_items:
        cleaned = str(item).strip()
        if not cleaned:
            continue
        normalized = normalize_name(cleaned)
        if normalized in seen:
            continue
        seen.add(normalized)
        tags.append(cleaned)
    return tags


def insert_item(connection, kind: str, name: str) -> None:
    cleaned = (name or "").strip()
    if not cleaned:
        return
    normalized_name = normalize_name(cleaned)
    if not normalized_name:
        return
    connection.execute(
        sa.text(
            """
            INSERT OR IGNORE INTO managed_list_items (
                id, kind, name, normalized_name, created_at, updated_at
            ) VALUES (
                lower(hex(randomblob(16))), :kind, :name, :normalized_name, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            """
        ),
        {"kind": kind, "name": cleaned, "normalized_name": normalized_name},
    )


def upgrade() -> None:
    op.create_table(
        "managed_list_items",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("kind", sa.String(length=24), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("normalized_name", sa.String(length=120), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("kind", "normalized_name", name="uq_managed_list_kind_name"),
    )
    op.create_index("ix_managed_list_items_normalized_name", "managed_list_items", ["normalized_name"], unique=False)
    op.add_column("recipe_steps", sa.Column("parent_step_id", sa.String(length=140), nullable=True))
    op.create_index("ix_recipe_steps_parent_step_id", "recipe_steps", ["parent_step_id"], unique=False)
    op.add_column("week_meals", sa.Column("scale_multiplier", sa.Float(), nullable=False, server_default="1.0"))

    connection = op.get_bind()
    for kind, names in DEFAULTS.items():
        for name in names:
            insert_item(connection, kind, name)

    recipes = connection.execute(sa.text("SELECT cuisine, tags FROM recipes")).mappings().all()
    for recipe in recipes:
        insert_item(connection, "cuisine", str(recipe["cuisine"] or ""))
        for tag in extract_tags(str(recipe["tags"] or "")):
            insert_item(connection, "tag", tag)

    ingredients = connection.execute(sa.text("SELECT unit FROM recipe_ingredients")).mappings().all()
    for ingredient in ingredients:
        insert_item(connection, "unit", str(ingredient["unit"] or ""))


def downgrade() -> None:
    op.drop_column("week_meals", "scale_multiplier")
    op.drop_index("ix_recipe_steps_parent_step_id", table_name="recipe_steps")
    op.drop_column("recipe_steps", "parent_step_id")
    op.drop_index("ix_managed_list_items_normalized_name", table_name="managed_list_items")
    op.drop_table("managed_list_items")
