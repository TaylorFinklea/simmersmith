"""Add difficulty_score (1-5, AI-inferred) and kid_friendly to recipes.

Difficulty lets the Recipes view filter on Easy / Medium / Hard. The
score is AI-inferred opportunistically when a recipe is created without
one. NULL = not yet scored. kid_friendly is a separate boolean — being
"easy" doesn't imply "good with kids."

Revision ID: 20260425_0021
Revises: 20260424_0020
Create Date: 2026-04-25 12:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260425_0021"
down_revision = "20260424_0020"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("recipes") as batch:
        batch.add_column(sa.Column("difficulty_score", sa.Integer(), nullable=True))
        batch.add_column(
            sa.Column(
                "kid_friendly",
                sa.Boolean(),
                nullable=False,
                server_default=sa.text("0"),
            )
        )
        batch.create_check_constraint(
            "ck_recipes_difficulty_score_range",
            "difficulty_score IS NULL OR (difficulty_score BETWEEN 1 AND 5)",
        )


def downgrade() -> None:
    with op.batch_alter_table("recipes") as batch:
        batch.drop_constraint("ck_recipes_difficulty_score_range", type_="check")
        batch.drop_column("kid_friendly")
        batch.drop_column("difficulty_score")
