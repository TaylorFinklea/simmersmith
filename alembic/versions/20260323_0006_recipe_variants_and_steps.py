"""Add recipe variants, memories, and structured steps.

Revision ID: 20260323_0006
Revises: 20260322_0005
Create Date: 2026-03-23 14:00:00
"""
from __future__ import annotations

import re

from alembic import op
import sqlalchemy as sa


revision = "20260323_0006"
down_revision = "20260322_0005"
branch_labels = None
depends_on = None


RECIPE_STEP_SPLIT_RE = re.compile(r"(?:\s*\d+[\).\s-]+)|(?:\.\s+)")


def split_summary(summary: str) -> list[str]:
    cleaned = (summary or "").strip()
    if not cleaned:
        return []
    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if len(lines) > 1:
        return [re.sub(r"^\d+[\).\s-]+", "", line).strip() for line in lines]
    return [part.strip() for part in RECIPE_STEP_SPLIT_RE.split(cleaned) if part and part.strip()] or [cleaned]


def upgrade() -> None:
    op.add_column("recipes", sa.Column("base_recipe_id", sa.String(length=120), nullable=True))
    op.add_column("recipes", sa.Column("memories", sa.Text(), nullable=False, server_default=""))
    op.add_column("recipes", sa.Column("override_payload_json", sa.Text(), nullable=False, server_default="{}"))
    op.create_index("ix_recipes_base_recipe_id", "recipes", ["base_recipe_id"], unique=False)

    op.create_table(
        "recipe_steps",
        sa.Column("id", sa.String(length=140), nullable=False),
        sa.Column("recipe_id", sa.String(length=120), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("instruction", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )

    connection = op.get_bind()
    recipes = connection.execute(sa.text("SELECT id, instructions_summary FROM recipes")).mappings().all()
    for recipe in recipes:
        for index, instruction in enumerate(split_summary(str(recipe["instructions_summary"] or "")), start=1):
            connection.execute(
                sa.text(
                    """
                    INSERT INTO recipe_steps (id, recipe_id, sort_order, instruction, created_at, updated_at)
                    VALUES (:id, :recipe_id, :sort_order, :instruction, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                    """
                ),
                {
                    "id": f"{recipe['id']}-step-{index}",
                    "recipe_id": recipe["id"],
                    "sort_order": index,
                    "instruction": instruction,
                },
            )


def downgrade() -> None:
    op.drop_table("recipe_steps")
    op.drop_index("ix_recipes_base_recipe_id", table_name="recipes")
    op.drop_column("recipes", "override_payload_json")
    op.drop_column("recipes", "memories")
    op.drop_column("recipes", "base_recipe_id")
