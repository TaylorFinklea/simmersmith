"""Add recipe archive metadata.

Revision ID: 20260321_0004
Revises: 20260316_0003
Create Date: 2026-03-21 15:35:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260321_0004"
down_revision = "20260316_0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("recipes", sa.Column("archived", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column("recipes", sa.Column("archived_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("recipes", "archived_at")
    op.drop_column("recipes", "archived")
