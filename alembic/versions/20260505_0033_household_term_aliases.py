"""M26 Phase 3: per-household shorthand dictionary.

`HouseholdTermAlias` lets a household register custom shorthand
words (e.g. "chx" → "chicken", "tw" → "Trader Joe's") that the AI
should treat as their canonical expansion in both planner and
assistant flows. Per-household so two families can hold different
abbreviations without collision.

Schema:
    household_term_aliases (
        id, household_id, term, expansion, notes,
        created_at, updated_at
    )
    UNIQUE (household_id, term)
    INDEX ix_household_term_aliases_household_id

Terms are stored lowercase-normalized so "CHX", "Chx", "chx" all
collide on the same slot.

Revision ID: 20260505_0033
Revises: 20260505_0032
Create Date: 2026-05-05 09:30:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260505_0033"
down_revision = "20260505_0032"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "household_term_aliases",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("household_id", sa.String(36), nullable=False),
        sa.Column("term", sa.String(120), nullable=False),
        sa.Column("expansion", sa.String(255), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("household_id", "term", name="uq_household_term_aliases_household_term"),
    )
    op.create_index(
        "ix_household_term_aliases_household_id",
        "household_term_aliases",
        ["household_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_household_term_aliases_household_id", table_name="household_term_aliases")
    op.drop_table("household_term_aliases")
