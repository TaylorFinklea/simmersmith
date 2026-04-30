"""M17.1 image-gen cost telemetry: create image_gen_usage table.

Revision ID: 20260430_0026
Revises: 20260430_0025
Create Date: 2026-04-30 12:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = "20260430_0026"
down_revision = "20260430_0025"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "image_gen_usage",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("user_id", sa.String(36), nullable=False, index=True),
        sa.Column("recipe_id", sa.String(120), nullable=True),
        sa.Column("provider", sa.String(16), nullable=False),
        sa.Column("model", sa.String(80), nullable=False),
        sa.Column("est_cost_cents", sa.Integer(), nullable=False),
        sa.Column("trigger", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, index=True),
        sa.PrimaryKeyConstraint("id"),
        sa.Index("ix_image_gen_usage_user_id_created_at", "user_id", "created_at"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="SET NULL"),
    )


def downgrade() -> None:
    op.drop_table("image_gen_usage")
