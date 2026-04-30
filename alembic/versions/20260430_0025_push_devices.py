"""Add push_devices table (M18 push notifications).

Stores per-device APNs tokens. Keyed by (user_id, device_token) with
disabled_at nullable so we can soft-disable 410 Unregistered tokens
without deleting them (audit trail + avoids accidental re-registration
churn if the client re-sends the same token after a 410).

Revision ID: 20260430_0025
Revises: 20260427_0024
Create Date: 2026-04-30 00:00:00
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260430_0025"
down_revision = "20260427_0024"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "push_devices",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("user_id", sa.String(36), nullable=False, index=True),
        sa.Column("device_token", sa.String(200), nullable=False),
        sa.Column("platform", sa.String(16), nullable=False, server_default="ios"),
        sa.Column("apns_environment", sa.String(16), nullable=False, server_default="sandbox"),
        sa.Column("bundle_id", sa.String(120), nullable=False, server_default=""),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("disabled_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "device_token", name="uq_push_devices_user_token"),
    )


def downgrade() -> None:
    op.drop_table("push_devices")
