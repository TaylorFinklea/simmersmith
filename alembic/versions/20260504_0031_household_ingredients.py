"""M25: household-scoped ingredient catalog with submission lifecycle.

The `BaseIngredient` table has been globally scoped since M9 — no
`household_id`, no submission lifecycle, anybody can create anything.
M25 adds a per-household visibility scope plus a four-state lifecycle
so the catalog supports three modes:

- `approved` (the existing global master list, household_id NULL)
- `submitted` (household-authored, awaiting admin review)
- `household_only` (household-authored, never submitted; private)
- `rejected` (admin declined the submission, kept for audit)

Schema delta:
- Add `household_id` (String(36), nullable, indexed).
- Add `submission_status` (String(24), NOT NULL, default 'approved').
- Replace the implicit `UNIQUE (normalized_name)` with two partial
  uniques so two households can each have a private "Cherry tomato"
  while preserving global uniqueness for `approved` rows:
    - UNIQUE (normalized_name) WHERE household_id IS NULL
    - UNIQUE (normalized_name, household_id) WHERE household_id IS NOT NULL

Backfill: every existing row → `submission_status='approved'`,
`household_id=NULL`. The legacy `provisional=True` flag still sets
on auto-resolver-created rows but is now decorative; the new logic
keys off `submission_status`.

Revision ID: 20260504_0031
Revises: 20260504_0030
Create Date: 2026-05-04 14:00:00.000000
"""
import sqlalchemy as sa

from alembic import op


revision = "20260504_0031"
down_revision = "20260504_0030"
branch_labels = None
depends_on = None


OLD_NORMALIZED_INDEX = "ix_base_ingredients_normalized_name"
GLOBAL_PARTIAL_UNIQUE = "uq_base_ingredients_global_normalized_name"
HOUSEHOLD_UNIQUE = "uq_base_ingredients_household_normalized_name"
HOUSEHOLD_LOOKUP_INDEX = "ix_base_ingredients_household_id"


def upgrade() -> None:
    op.add_column(
        "base_ingredients",
        sa.Column("household_id", sa.String(36), nullable=True),
    )
    op.add_column(
        "base_ingredients",
        sa.Column(
            "submission_status",
            sa.String(24),
            nullable=False,
            server_default="approved",
        ),
    )
    op.create_index(HOUSEHOLD_LOOKUP_INDEX, "base_ingredients", ["household_id"])

    bind = op.get_bind()
    if bind.dialect.name == "sqlite":
        # SQLite path. The 0001 migration declared `normalized_name`
        # as `unique=True`, which SQLAlchemy generates as a CHECK-
        # like UNIQUE constraint baked into CREATE TABLE.
        # Inspecting an installed SQLite DB shows the constraint
        # auto-named `sqlite_autoindex_base_ingredients_<n>`. We
        # don't reference that name — instead, batch_alter_table
        # with `copy_from` lets us rebuild the table using a
        # SQLAlchemy Table object that EXPLICITLY omits the unique
        # constraint, sidestepping the auto-name discovery problem.
        from sqlalchemy import Table, MetaData, Column, Boolean, Float, ForeignKey, Text, Integer, DateTime

        meta = MetaData()
        new_table = Table(
            "base_ingredients", meta,
            Column("id", sa.String(36), primary_key=True),
            Column("name", sa.String(255), nullable=False),
            # No unique here — that's the whole point.
            Column("normalized_name", sa.String(255), nullable=False),
            Column("household_id", sa.String(36), nullable=True),
            Column("submission_status", sa.String(24), nullable=False, server_default="approved"),
            Column("category", sa.String(120), nullable=False, server_default=""),
            Column("default_unit", sa.String(40), nullable=False, server_default=""),
            Column("notes", sa.Text(), nullable=False, server_default=""),
            Column("source_name", sa.String(40), nullable=False, server_default=""),
            Column("source_record_id", sa.String(120), nullable=False, server_default=""),
            Column("source_url", sa.Text(), nullable=False, server_default=""),
            Column("source_payload_json", sa.Text(), nullable=False, server_default="{}"),
            Column("override_payload_json", sa.Text(), nullable=False, server_default="{}"),
            Column("provisional", sa.Boolean(), nullable=False, server_default=sa.text("0")),
            Column("active", sa.Boolean(), nullable=False, server_default=sa.text("1")),
            Column("archived_at", sa.DateTime(timezone=True), nullable=True),
            Column("merged_into_id", sa.String(36), sa.ForeignKey("base_ingredients.id", ondelete="SET NULL"), nullable=True),
            Column("nutrition_reference_amount", sa.Float(), nullable=True),
            Column("nutrition_reference_unit", sa.String(40), nullable=False, server_default=""),
            Column("calories", sa.Float(), nullable=True),
            Column("protein_g", sa.Float(), nullable=True),
            Column("carbs_g", sa.Float(), nullable=True),
            Column("fat_g", sa.Float(), nullable=True),
            Column("fiber_g", sa.Float(), nullable=True),
            Column("created_at", sa.DateTime(timezone=True), nullable=False),
            Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        )
        with op.batch_alter_table("base_ingredients", copy_from=new_table) as batch:
            batch.alter_column(
                "normalized_name",
                existing_type=sa.String(255),
                existing_nullable=False,
            )
        op.create_index(
            GLOBAL_PARTIAL_UNIQUE,
            "base_ingredients",
            ["normalized_name"],
            unique=True,
            sqlite_where=sa.text("household_id IS NULL"),
        )
        op.create_index(
            HOUSEHOLD_UNIQUE,
            "base_ingredients",
            ["normalized_name", "household_id"],
            unique=True,
            sqlite_where=sa.text("household_id IS NOT NULL"),
        )
    else:
        # Postgres path. SQLAlchemy's `unique=True` on a column declares
        # both an implicit UNIQUE constraint (auto-named
        # `<table>_<column>_key`) and a backing index. We can't predict
        # the exact constraint name across SQLAlchemy versions, so use
        # introspection: find any UNIQUE constraint that covers
        # `normalized_name` and drop it explicitly. This also handles
        # historical drift where the constraint was renamed manually.
        bind_pg = op.get_bind()
        unique_constraints = bind_pg.execute(sa.text(
            """
            SELECT con.conname
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY(con.conkey)
            WHERE rel.relname = 'base_ingredients'
              AND con.contype = 'u'
              AND att.attname = 'normalized_name'
              AND array_length(con.conkey, 1) = 1
            """
        )).fetchall()
        for (conname,) in unique_constraints:
            op.execute(sa.text(f'ALTER TABLE base_ingredients DROP CONSTRAINT IF EXISTS "{conname}"'))
        # The legacy `index=True` index might also exist with a UNIQUE
        # backing — drop it if so, then recreate non-unique for lookup.
        op.execute(sa.text(f'DROP INDEX IF EXISTS "{OLD_NORMALIZED_INDEX}"'))
        op.create_index(OLD_NORMALIZED_INDEX, "base_ingredients", ["normalized_name"], unique=False)
        op.create_index(
            GLOBAL_PARTIAL_UNIQUE,
            "base_ingredients",
            ["normalized_name"],
            unique=True,
            postgresql_where=sa.text("household_id IS NULL"),
        )
        op.create_index(
            HOUSEHOLD_UNIQUE,
            "base_ingredients",
            ["normalized_name", "household_id"],
            unique=True,
            postgresql_where=sa.text("household_id IS NOT NULL"),
        )


def downgrade() -> None:
    op.drop_index(HOUSEHOLD_UNIQUE, table_name="base_ingredients")
    op.drop_index(GLOBAL_PARTIAL_UNIQUE, table_name="base_ingredients")
    op.drop_index(OLD_NORMALIZED_INDEX, table_name="base_ingredients")
    op.create_index(
        OLD_NORMALIZED_INDEX,
        "base_ingredients",
        ["normalized_name"],
        unique=True,
    )
    op.drop_index(HOUSEHOLD_LOOKUP_INDEX, table_name="base_ingredients")
    op.drop_column("base_ingredients", "submission_status")
    op.drop_column("base_ingredients", "household_id")
