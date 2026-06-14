"""T1: re-key weeks + staples UNIQUE constraints to household_id (finish M21).

Post-M21 the tenancy unit is the household, but two integrity invariants were
still keyed on user_id:

  weeks    UNIQUE(user_id, week_start)       -> should be (household_id, week_start)
  staples  UNIQUE(user_id, normalized_name)  -> should be (household_id, normalized_name)

Because a household can have multiple members, user_id keying let two members
create duplicate weeks for one (household, week_start) and duplicate pantry
staples for one (household, name): the service layer deduped household-wide but
the DB did not enforce it, so a TOCTOU race (two members planning the same week
concurrently) or a per-member profile/pantry write produced duplicate /
conflicting rows.

Production data may already hold such duplicates from past races, so the
upgrade de-dupes first (or the new constraint creation would fail):

  weeks   - keep the row with the most meals, then the most-recently-updated;
            delete the rest. Child rows fall away via ondelete=CASCADE on
            Postgres; on SQLite the test DB is freshly migrated and empty so the
            loop is a no-op.
  staples - keep the active, most-recently-updated row per (household, name).

De-dupe runs in Python over the bound connection so it behaves identically on
SQLite (tests) and Postgres (prod).

Dialect split for the constraint swap. SQLite cannot ALTER ... DROP CONSTRAINT,
and Alembic's batch mode can't reflect the *name* of an inline UNIQUE constraint
to drop it (no metadata naming_convention is configured). So:

  Postgres (prod) - drop the old user-keyed UNIQUE constraint and create the new
                    household-keyed one by name (the clean, model-matching state).
  SQLite (tests)  - add the new invariant as a UNIQUE INDEX, which enforces the
                    same uniqueness without a table rebuild. The now-redundant
                    old user-keyed UNIQUE stays in place; it is harmless because
                    for any valid household-deduped data it is strictly implied
                    by the new constraint, and it never rejects a legitimate
                    cross-member row.

Revision ID: 20260613_0047
Revises: 20260530_0046
Create Date: 2026-06-13 00:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260613_0047"
down_revision = "20260530_0046"
branch_labels = None
depends_on = None


def _stale_ids(bind, *, select_sql: str, key_fields: tuple[str, ...]) -> list[str]:
    """Return the ids of duplicate rows to delete, keeping the first row per
    key in the order returned by ``select_sql`` (the keep-policy is encoded in
    that query's ORDER BY)."""
    rows = bind.execute(sa.text(select_sql)).mappings().all()
    seen: set[tuple] = set()
    stale: list[str] = []
    for row in rows:
        key = tuple(row[field] for field in key_fields)
        if key in seen:
            stale.append(row["id"])
        else:
            seen.add(key)
    return stale


def upgrade() -> None:
    bind = op.get_bind()

    # De-dupe weeks on (household_id, week_start): keep the most-planned, then
    # the most-recently-updated. Deleting a duplicate week cascades to its
    # children on Postgres (ondelete=CASCADE).
    for week_id in _stale_ids(
        bind,
        select_sql=(
            "SELECT w.id AS id, w.household_id AS household_id, w.week_start AS week_start "
            "FROM weeks w "
            "ORDER BY w.household_id, w.week_start, "
            "(SELECT COUNT(*) FROM week_meals m WHERE m.week_id = w.id) DESC, "
            "w.updated_at DESC"
        ),
        key_fields=("household_id", "week_start"),
    ):
        bind.execute(sa.text("DELETE FROM weeks WHERE id = :id"), {"id": week_id})

    # De-dupe staples on (household_id, normalized_name): keep the active,
    # most-recently-updated row.
    for staple_id in _stale_ids(
        bind,
        select_sql=(
            "SELECT id, household_id, normalized_name "
            "FROM staples "
            "ORDER BY household_id, normalized_name, is_active DESC, updated_at DESC"
        ),
        key_fields=("household_id", "normalized_name"),
    ):
        bind.execute(sa.text("DELETE FROM staples WHERE id = :id"), {"id": staple_id})

    if bind.dialect.name == "postgresql":
        op.drop_constraint("uq_weeks_user_week_start", "weeks", type_="unique")
        op.create_unique_constraint(
            "uq_weeks_household_week_start", "weeks", ["household_id", "week_start"]
        )
        op.drop_constraint("uq_staples_user_normalized_name", "staples", type_="unique")
        op.create_unique_constraint(
            "uq_staples_household_normalized_name",
            "staples",
            ["household_id", "normalized_name"],
        )
    else:
        op.create_index(
            "uq_weeks_household_week_start",
            "weeks",
            ["household_id", "week_start"],
            unique=True,
        )
        op.create_index(
            "uq_staples_household_normalized_name",
            "staples",
            ["household_id", "normalized_name"],
            unique=True,
        )


def downgrade() -> None:
    bind = op.get_bind()
    if bind.dialect.name == "postgresql":
        op.drop_constraint("uq_staples_household_normalized_name", "staples", type_="unique")
        op.create_unique_constraint(
            "uq_staples_user_normalized_name", "staples", ["user_id", "normalized_name"]
        )
        op.drop_constraint("uq_weeks_household_week_start", "weeks", type_="unique")
        op.create_unique_constraint(
            "uq_weeks_user_week_start", "weeks", ["user_id", "week_start"]
        )
    else:
        op.drop_index("uq_staples_household_normalized_name", "staples")
        op.drop_index("uq_weeks_household_week_start", "weeks")
