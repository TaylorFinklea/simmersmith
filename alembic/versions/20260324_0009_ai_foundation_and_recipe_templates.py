"""Add recipe templates and AI foundation settings support.

Revision ID: 20260324_0009
Revises: 20260324_0008
Create Date: 2026-03-24 15:15:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260324_0009"
down_revision = "20260324_0008"
branch_labels = None
depends_on = None


DEFAULT_TEMPLATE_ID = "recipe-template-standard"
DEFAULT_TEMPLATES = (
    {
        "id": DEFAULT_TEMPLATE_ID,
        "slug": "standard",
        "name": "Standard",
        "description": "Balanced recipe card with ingredients, steps, notes, and source context.",
        "section_order_json": '["title","meta","source","memories","ingredients","steps","notes","nutrition"]',
        "share_source": True,
        "share_memories": True,
        "built_in": True,
    },
    {
        "id": "recipe-template-weeknight",
        "slug": "weeknight",
        "name": "Weeknight",
        "description": "Compact layout for fast dinner execution.",
        "section_order_json": '["title","meta","ingredients","steps","notes","nutrition"]',
        "share_source": False,
        "share_memories": False,
        "built_in": True,
    },
    {
        "id": "recipe-template-story",
        "slug": "story",
        "name": "Story",
        "description": "Keeps provenance and memories visible for family recipes and keepsakes.",
        "section_order_json": '["title","source","memories","meta","ingredients","steps","notes","nutrition"]',
        "share_source": True,
        "share_memories": True,
        "built_in": True,
    },
)


def upgrade() -> None:
    op.create_table(
        "recipe_templates",
        sa.Column("id", sa.String(length=120), nullable=False),
        sa.Column("slug", sa.String(length=120), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("description", sa.Text(), nullable=False, server_default=""),
        sa.Column("section_order_json", sa.Text(), nullable=False, server_default="[]"),
        sa.Column("share_source", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("share_memories", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("built_in", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.text("CURRENT_TIMESTAMP")),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("slug"),
    )
    op.create_index("ix_recipe_templates_slug", "recipe_templates", ["slug"], unique=False)

    recipe_templates = sa.table(
        "recipe_templates",
        sa.column("id", sa.String(length=120)),
        sa.column("slug", sa.String(length=120)),
        sa.column("name", sa.String(length=120)),
        sa.column("description", sa.Text()),
        sa.column("section_order_json", sa.Text()),
        sa.column("share_source", sa.Boolean()),
        sa.column("share_memories", sa.Boolean()),
        sa.column("built_in", sa.Boolean()),
    )
    op.bulk_insert(recipe_templates, list(DEFAULT_TEMPLATES))

    with op.batch_alter_table("recipes", recreate="auto") as batch_op:
        batch_op.add_column(
            sa.Column("recipe_template_id", sa.String(length=120), nullable=True, server_default=DEFAULT_TEMPLATE_ID),
        )
        batch_op.create_index("ix_recipes_recipe_template_id", ["recipe_template_id"], unique=False)
        batch_op.create_foreign_key(
            "fk_recipes_recipe_template_id",
            "recipe_templates",
            ["recipe_template_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    with op.batch_alter_table("recipes", recreate="auto") as batch_op:
        batch_op.drop_constraint("fk_recipes_recipe_template_id", type_="foreignkey")
        batch_op.drop_index("ix_recipes_recipe_template_id")
        batch_op.drop_column("recipe_template_id")
    op.drop_index("ix_recipe_templates_slug", table_name="recipe_templates")
    op.drop_table("recipe_templates")
