"""Persist assistant provider thread identifiers.

Revision ID: 20260329_0011
Revises: 20260328_0010
Create Date: 2026-03-29 16:30:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260329_0011"
down_revision = "20260328_0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "assistant_threads",
        sa.Column("provider_thread_id", sa.String(length=120), nullable=False, server_default=""),
    )


def downgrade() -> None:
    op.drop_column("assistant_threads", "provider_thread_id")
