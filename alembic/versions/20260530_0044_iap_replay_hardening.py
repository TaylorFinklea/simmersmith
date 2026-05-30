"""IAP replay/dedup hardening (F23/F24).

- New ``processed_apple_notifications`` table: dedup App Store Server
  Notification v2 deliveries by ``notificationUUID`` so a replayed
  webhook is ignored instead of re-applied.
- ``subscriptions.last_transaction_id``: latest applied Apple
  transactionId, for a monotonic (ignore-older) guard.
- ``subscriptions.app_account_token``: the appAccountToken Apple echoes
  when the iOS client sets it at purchase, so a receipt can't be re-bound
  to a different account (forward-compatible — inert until iOS sets it).

Revision ID: 20260530_0044
Revises: 20260530_0043
Create Date: 2026-05-30 12:30:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260530_0044"
down_revision = "20260530_0043"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "processed_apple_notifications",
        sa.Column("notification_uuid", sa.String(length=64), primary_key=True),
        sa.Column("notification_type", sa.String(length=64), nullable=False, server_default=""),
        sa.Column("subtype", sa.String(length=64), nullable=False, server_default=""),
        sa.Column(
            "processed_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
    )
    with op.batch_alter_table("subscriptions") as batch_op:
        batch_op.add_column(sa.Column("last_transaction_id", sa.String(length=40), nullable=True))
        batch_op.add_column(sa.Column("app_account_token", sa.String(length=64), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("subscriptions") as batch_op:
        batch_op.drop_column("app_account_token")
        batch_op.drop_column("last_transaction_id")
    op.drop_table("processed_apple_notifications")
