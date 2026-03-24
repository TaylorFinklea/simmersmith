"""Add preference memory signals.

Revision ID: 20260313_0002
Revises: 20260312_0001
Create Date: 2026-03-13 00:02:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260313_0002"
down_revision = "20260312_0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "preference_signals",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("signal_type", sa.String(length=40), nullable=False),
        sa.Column("name", sa.String(length=255), nullable=False),
        sa.Column("normalized_name", sa.String(length=255), nullable=False),
        sa.Column("score", sa.Integer(), nullable=False),
        sa.Column("weight", sa.Integer(), nullable=False),
        sa.Column("rationale", sa.Text(), nullable=False),
        sa.Column("source", sa.String(length=40), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("signal_type", "normalized_name", name="uq_signal_type_name"),
    )
    op.create_index(
        op.f("ix_preference_signals_normalized_name"),
        "preference_signals",
        ["normalized_name"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_preference_signals_normalized_name"), table_name="preference_signals")
    op.drop_table("preference_signals")
