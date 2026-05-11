"""Build 94: editable server settings.

Adds a key/value table for operator-tunable knobs (free-tier limits,
default AI models, trial-mode toggle). The values are strings; typed
accessors live in ``app.services.server_settings`` and parse via JSON
where needed (e.g. the free-tier limits dict).

Revision ID: 20260511_0039
Revises: 20260510_0038
Create Date: 2026-05-11 06:30:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260511_0039"
down_revision = "20260510_0038"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "server_settings",
        sa.Column("key", sa.String(length=120), primary_key=True),
        sa.Column("value", sa.Text(), nullable=False, server_default=""),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("CURRENT_TIMESTAMP"),
        ),
    )


def downgrade() -> None:
    op.drop_table("server_settings")
