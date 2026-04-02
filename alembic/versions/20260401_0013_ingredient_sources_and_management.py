"""Add ingredient source metadata and management fields.

Revision ID: 20260401_0013
Revises: 20260330_0012
Create Date: 2026-04-01 16:15:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260401_0013"
down_revision = "20260330_0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("base_ingredients") as batch_op:
        batch_op.add_column(sa.Column("source_name", sa.String(length=40), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_record_id", sa.String(length=120), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_url", sa.Text(), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_payload_json", sa.Text(), nullable=False, server_default="{}"))
        batch_op.add_column(sa.Column("override_payload_json", sa.Text(), nullable=False, server_default="{}"))
        batch_op.add_column(sa.Column("provisional", sa.Boolean(), nullable=False, server_default=sa.false()))
        batch_op.add_column(sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column("merged_into_id", sa.String(length=36), nullable=True))
        batch_op.create_index("ix_base_ingredients_merged_into_id", ["merged_into_id"])
        batch_op.create_foreign_key(
            "fk_base_ingredients_merged_into_id",
            "base_ingredients",
            ["merged_into_id"],
            ["id"],
            ondelete="SET NULL",
        )

    with op.batch_alter_table("ingredient_variations") as batch_op:
        batch_op.add_column(sa.Column("upc", sa.String(length=40), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_name", sa.String(length=40), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_record_id", sa.String(length=120), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_url", sa.Text(), nullable=False, server_default=""))
        batch_op.add_column(sa.Column("source_payload_json", sa.Text(), nullable=False, server_default="{}"))
        batch_op.add_column(sa.Column("override_payload_json", sa.Text(), nullable=False, server_default="{}"))
        batch_op.add_column(sa.Column("active", sa.Boolean(), nullable=False, server_default=sa.true()))
        batch_op.add_column(sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True))
        batch_op.add_column(sa.Column("merged_into_id", sa.String(length=36), nullable=True))
        batch_op.create_index("ix_ingredient_variations_merged_into_id", ["merged_into_id"])
        batch_op.create_foreign_key(
            "fk_ingredient_variations_merged_into_id",
            "ingredient_variations",
            ["merged_into_id"],
            ["id"],
            ondelete="SET NULL",
        )


def downgrade() -> None:
    with op.batch_alter_table("ingredient_variations") as batch_op:
        batch_op.drop_constraint("fk_ingredient_variations_merged_into_id", type_="foreignkey")
        batch_op.drop_index("ix_ingredient_variations_merged_into_id")
        batch_op.drop_column("merged_into_id")
        batch_op.drop_column("archived_at")
        batch_op.drop_column("active")
        batch_op.drop_column("override_payload_json")
        batch_op.drop_column("source_payload_json")
        batch_op.drop_column("source_url")
        batch_op.drop_column("source_record_id")
        batch_op.drop_column("source_name")
        batch_op.drop_column("upc")

    with op.batch_alter_table("base_ingredients") as batch_op:
        batch_op.drop_constraint("fk_base_ingredients_merged_into_id", type_="foreignkey")
        batch_op.drop_index("ix_base_ingredients_merged_into_id")
        batch_op.drop_column("merged_into_id")
        batch_op.drop_column("archived_at")
        batch_op.drop_column("active")
        batch_op.drop_column("provisional")
        batch_op.drop_column("override_payload_json")
        batch_op.drop_column("source_payload_json")
        batch_op.drop_column("source_url")
        batch_op.drop_column("source_record_id")
        batch_op.drop_column("source_name")
