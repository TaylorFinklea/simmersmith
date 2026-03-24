"""Add recipe source metadata.

Revision ID: 20260322_0005
Revises: 20260321_0004
Create Date: 2026-03-22 09:30:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260322_0005"
down_revision = "20260321_0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("recipes", sa.Column("source_label", sa.String(length=255), nullable=False, server_default=""))
    op.add_column("recipes", sa.Column("source_url", sa.Text(), nullable=False, server_default=""))


def downgrade() -> None:
    op.drop_column("recipes", "source_url")
    op.drop_column("recipes", "source_label")
