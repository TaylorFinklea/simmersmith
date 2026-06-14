"""T4: add events.manually_merged to pin user-initiated grocery merges.

The event→week grocery merge state was tracked by just
``(auto_merge_grocery, linked_week_id)``, which can't tell three cases apart:

  - auto-merged into the date-covering week (re-point when the date moves),
  - the user explicitly merged into a chosen week (keep it pinned on edits),
  - auto-merge was toggled OFF (unmerge the prior auto link).

So editing a manually-merged potluck (auto_merge_grocery=False) silently dropped
the merge: ``apply_auto_merge_policy`` read False+linked as "should be unmerged".

This adds ``manually_merged`` (default False). The manual /grocery/merge endpoint
sets it True; the policy then keeps that event pinned to ``linked_week_id`` and
never auto-unmerges or auto-re-points it. The explicit unmerge endpoint clears it.

Revision ID: 20260614_0048
Revises: 20260613_0047
Create Date: 2026-06-14 00:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260614_0048"
down_revision = "20260613_0047"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("events") as batch_op:
        batch_op.add_column(
            sa.Column(
                "manually_merged",
                sa.Boolean(),
                nullable=False,
                server_default=sa.false(),
            )
        )


def downgrade() -> None:
    with op.batch_alter_table("events") as batch_op:
        batch_op.drop_column("manually_merged")
