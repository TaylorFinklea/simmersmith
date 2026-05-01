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

    # 2 + 3. Create one solo household per existing user via pure SQL.
    # Reuse the user's id as the household id so the backfill UPDATE
    # below is a one-liner (`household_id = user_id`).
    #
    # Both `INSERT ... SELECT` statements are wrapped in the alembic
    # transaction; if either fails the whole migration rolls back. They
    # are deliberately plain SQL — no Python iteration over result sets,
    # no nested `bind.execute` cursors that could leak across statements.
    op.execute(
        sa.text(
            "INSERT INTO households (id, name, created_by_user_id, created_at, updated_at) "
            "SELECT id, '', id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM users"
        )
    )
    op.execute(
        sa.text(
            "INSERT INTO household_members (id, household_id, user_id, role, joined_at) "
            "SELECT 'hhm-' || id, id, id, 'owner', CURRENT_TIMESTAMP FROM users"
        )
    )

    # 4. Add `household_id` column to each shared table as **nullable**.
    # Phase 1 is purely additive: backfill existing rows, but new rows
    # written by ORM code (which doesn't know about household_id yet)
    # are allowed to have NULL until Phase 2 wires the writers and
    # flips the column NOT NULL.
    for table in SHARED_TABLES:
        op.add_column(
            table,
            sa.Column("household_id", sa.String(36), nullable=True),
        )
        op.create_index(
            f"ix_{table}_household_id", table, ["household_id"], unique=False
        )

    # 5. Backfill household_id from the user's solo household. Steps 2/3
    # used user_id as the household_id, so this is a single
    # `SET household_id = user_id` per shared table.
    for table in SHARED_TABLES:
        op.execute(sa.text(f"UPDATE {table} SET household_id = user_id"))


def downgrade() -> None:
    for table in SHARED_TABLES:
        op.drop_index(f"ix_{table}_household_id", table_name=table)
        op.drop_column(table, "household_id")

    op.drop_table("household_settings")
    op.drop_table("household_invitations")
    op.drop_table("household_members")
    op.drop_table("households")
