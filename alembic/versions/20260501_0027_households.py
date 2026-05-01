"""M21 Phase 1: household sharing schema.

Adds the household tables (households, household_members,
household_invitations, household_settings), creates a solo household for
every existing user, and adds a `household_id` column to each shared
table (weeks, recipes, staples, events, guests), backfilled from the
single-member solo household for that user.

Phase 1 is intentionally **strictly additive** — every existing query
keeps working unchanged because:
  - The new `household_id` columns are populated but no service code
    reads them yet (Phase 2 flips queries from `user_id` to
    `household_id`).
  - `household_settings` is empty after this migration; the data move
    from `profile_settings` happens in Phase 2 alongside the readers
    that consume it.
  - The `user_id` columns and indexes on shared tables are NOT touched.

Revision ID: 20260501_0027
Revises: 20260430_0026
Create Date: 2026-05-01 00:00:00.000000
"""
from datetime import datetime, timezone

import sqlalchemy as sa

from alembic import op


# revision identifiers, used by Alembic.
revision = "20260501_0027"
down_revision = "20260430_0026"
branch_labels = None
depends_on = None


SHARED_TABLES = ("weeks", "recipes", "staples", "events", "guests")


def upgrade() -> None:
    # 1. Create the four new tables.
    op.create_table(
        "households",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("name", sa.String(120), nullable=False, server_default=""),
        sa.Column("created_by_user_id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )

    op.create_table(
        "household_members",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("household_id", sa.String(36), nullable=False),
        sa.Column("user_id", sa.String(36), nullable=False),
        sa.Column("role", sa.String(16), nullable=False, server_default="member"),
        sa.Column("joined_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "household_id", "user_id", name="uq_household_members_household_user"
        ),
        sa.Index("ix_household_members_household_id", "household_id"),
        sa.Index("ix_household_members_user_id", "user_id"),
        sa.ForeignKeyConstraint(
            ["household_id"], ["households.id"], ondelete="CASCADE"
        ),
    )

    op.create_table(
        "household_invitations",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("household_id", sa.String(36), nullable=False),
        sa.Column("code", sa.String(12), nullable=False),
        sa.Column("created_by_user_id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("claimed_by_user_id", sa.String(36), nullable=True),
        sa.Column("claimed_at", sa.DateTime(timezone=True), nullable=True),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("code", name="uq_household_invitations_code"),
        sa.Index("ix_household_invitations_household_id", "household_id"),
        sa.ForeignKeyConstraint(
            ["household_id"], ["households.id"], ondelete="CASCADE"
        ),
    )

    op.create_table(
        "household_settings",
        sa.Column("household_id", sa.String(36), nullable=False),
        sa.Column("key", sa.String(80), nullable=False),
        sa.Column("value", sa.Text(), nullable=False, server_default=""),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("household_id", "key"),
        sa.ForeignKeyConstraint(
            ["household_id"], ["households.id"], ondelete="CASCADE"
        ),
    )

    # 2 + 3. Create one solo household per existing user, with that user as
    # the sole owner. Use a deterministic UUID-shaped id derived from the
    # user_id so re-running this migration on a fresh DB is reproducible.
    bind = op.get_bind()
    now = datetime.now(timezone.utc)

    # Pull every existing user_id. Anything in `weeks` etc. without a
    # corresponding user_id row is invalid pre-existing data; we still
    # generate a household for those users (best-effort) by also
    # discovering user_ids from the shared tables.
    users_q = bind.execute(sa.text("SELECT id FROM users"))
    user_ids: set[str] = {row[0] for row in users_q.fetchall()}

    for table in SHARED_TABLES:
        try:
            extra = bind.execute(sa.text(f"SELECT DISTINCT user_id FROM {table}"))
            for row in extra.fetchall():
                if row[0]:
                    user_ids.add(row[0])
        except Exception:
            # Table may not exist on a fresh DB before earlier migrations
            # are applied; harmless during downstream test runs.
            pass

    households_table = sa.table(
        "households",
        sa.column("id", sa.String),
        sa.column("name", sa.String),
        sa.column("created_by_user_id", sa.String),
        sa.column("created_at", sa.DateTime),
        sa.column("updated_at", sa.DateTime),
    )
    members_table = sa.table(
        "household_members",
        sa.column("id", sa.String),
        sa.column("household_id", sa.String),
        sa.column("user_id", sa.String),
        sa.column("role", sa.String),
        sa.column("joined_at", sa.DateTime),
    )

    for user_id in sorted(user_ids):
        # Reuse the user_id as the household_id for solo households so
        # backfill SQL is a single UPDATE expression (`SET household_id =
        # user_id`). We never expose this convention in code; the
        # backfill is a one-time data move.
        household_id = user_id
        op.execute(
            households_table.insert().values(
                id=household_id,
                name="",
                created_by_user_id=user_id,
                created_at=now,
                updated_at=now,
            )
        )
        op.execute(
            members_table.insert().values(
                id=f"hhm-{user_id}",
                household_id=household_id,
                user_id=user_id,
                role="owner",
                joined_at=now,
            )
        )

    # 4. Add `household_id` column to each shared table as **nullable**.
    # Phase 1 is purely additive: backfill existing rows, but new rows
    # written by ORM code (which doesn't know about household_id yet)
    # are allowed to have NULL until Phase 2 wires the writers and
    # flips the column NOT NULL.
    for table in SHARED_TABLES:
        with op.batch_alter_table(table, recreate="auto") as batch_op:
            batch_op.add_column(
                sa.Column(
                    "household_id",
                    sa.String(36),
                    nullable=True,
                )
            )
            batch_op.create_index(
                f"ix_{table}_household_id", ["household_id"], unique=False
            )

    # 5. Backfill household_id from the user_id-keyed solo household. We
    # used user_id as the household_id in step 2/3 so this is a single
    # `SET household_id = user_id` per table.
    for table in SHARED_TABLES:
        op.execute(
            sa.text(f"UPDATE {table} SET household_id = user_id")
        )


def downgrade() -> None:
    for table in SHARED_TABLES:
        with op.batch_alter_table(table, recreate="auto") as batch_op:
            batch_op.drop_index(f"ix_{table}_household_id")
            batch_op.drop_column("household_id")

    op.drop_table("household_settings")
    op.drop_table("household_invitations")
    op.drop_table("household_members")
    op.drop_table("households")
