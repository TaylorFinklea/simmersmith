"""Enforce one household membership per user at the schema level (M15).

``HouseholdMember`` only carried ``UNIQUE(household_id, user_id)`` — which
blocks a duplicate (household, user) pair but NOT the same user appearing in
two *different* households. The "each user belongs to exactly one household"
invariant was therefore enforced only in app logic, so a concurrent first
sign-in (two lazy ``create_solo_household`` calls racing) could insert two
memberships for one user under different household_ids.

This adds ``UNIQUE(user_id)`` so the DB rejects the second insert. Production
data may already hold duplicate memberships from past races, so the upgrade
first de-dupes — keeping the earliest-joined membership per user and deleting
the rest — before adding the constraint, or the constraint creation would
fail. The de-dupe is done in Python over the bound connection so it behaves
identically on SQLite (tests) and Postgres (prod).

Revision ID: 20260530_0046
Revises: 20260530_0045
Create Date: 2026-05-30 13:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260530_0046"
down_revision = "20260530_0045"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    # De-dupe: keep the earliest-joined membership per user_id, drop the rest
    # (a duplicate means the user is wrongly in two households — the earliest
    # is the canonical one). No-op on a healthy DB.
    rows = bind.execute(
        sa.text(
            "SELECT id, user_id FROM household_members ORDER BY user_id, joined_at"
        )
    ).fetchall()
    seen: set[str] = set()
    stale_ids: list[str] = []
    for member_id, user_id in rows:
        if user_id in seen:
            stale_ids.append(member_id)
        else:
            seen.add(user_id)
    for member_id in stale_ids:
        bind.execute(
            sa.text("DELETE FROM household_members WHERE id = :id"),
            {"id": member_id},
        )

    # batch_alter_table so SQLite (no ALTER ADD CONSTRAINT) recreates the
    # table; Postgres emits a plain ALTER TABLE ADD CONSTRAINT.
    with op.batch_alter_table("household_members") as batch_op:
        batch_op.create_unique_constraint("uq_household_members_user", ["user_id"])


def downgrade() -> None:
    with op.batch_alter_table("household_members") as batch_op:
        batch_op.drop_constraint("uq_household_members_user", type_="unique")
