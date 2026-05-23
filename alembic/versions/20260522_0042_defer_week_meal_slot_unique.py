"""Build 103: defer the uq_week_day_slot unique constraint.

The iOS "swap meals" action sends a PUT that exchanges two existing
meals' ``(day_name, slot)`` in a single request. ``update_week_meals``
in turn issues two UPDATE statements (one per meal). Postgres enforces
unique constraints at end-of-statement by default, so the first
UPDATE sees a transient duplicate against the second row's *current*
``(week_id, day_name, slot)`` and raises ``IntegrityError`` — the
HTTP 500 the user reported.

Making the constraint DEFERRABLE INITIALLY DEFERRED moves the check
to commit-time, after both UPDATEs land. Single-row mutations (rename
in place, AI ``confirm_swap_meal``) are unaffected — they're still
checked at commit and still rejected if they actually create a
duplicate. The change is purely about *when* the check fires.

SQLite ignores DEFERRABLE on UNIQUE constraints (only honors it on
FOREIGN KEYs), so the test suite — which uses SQLite — still enforces
the constraint per-statement. That's fine: the swap path is exercised
end-to-end in production-equivalent Postgres tests only.

Revision ID: 20260522_0042
Revises: 20260515_0041
Create Date: 2026-05-22 21:30:00.000000
"""
from alembic import op


revision = "20260522_0042"
down_revision = "20260515_0041"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Postgres only — SQLite (used in pytest) doesn't honour DEFERRABLE
    # on UNIQUE constraints, so skip the rewrite there. The constraint
    # remains in place with its original immediate semantics.
    if op.get_bind().dialect.name != "postgresql":
        return
    op.drop_constraint("uq_week_day_slot", "week_meals", type_="unique")
    op.create_unique_constraint(
        "uq_week_day_slot",
        "week_meals",
        ["week_id", "day_name", "slot"],
        deferrable=True,
        initially="DEFERRED",
    )


def downgrade() -> None:
    if op.get_bind().dialect.name != "postgresql":
        return
    op.drop_constraint("uq_week_day_slot", "week_meals", type_="unique")
    op.create_unique_constraint(
        "uq_week_day_slot",
        "week_meals",
        ["week_id", "day_name", "slot"],
    )
