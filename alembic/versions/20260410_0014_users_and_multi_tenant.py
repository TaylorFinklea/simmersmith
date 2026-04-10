"""Add users table and user_id to user-owned tables.

Creates the users table for Apple/Google auth, then adds user_id to all
user-owned root tables. Catalog tables (base_ingredients, etc.) are
shared reference data and are NOT modified.

On Postgres: uses ALTER TABLE directly (supports DROP CONSTRAINT by name).
On SQLite: uses manual table recreation for inline UNIQUE constraints.

Revision ID: 20260410_0014
Revises: 20260401_0013
Create Date: 2026-04-10 12:00:00
"""
from __future__ import annotations

import os

from alembic import op
import sqlalchemy as sa

revision = "20260410_0014"
down_revision = "20260401_0013"
branch_labels = None
depends_on = None

LOCAL_USER_ID = os.environ.get(
    "SIMMERSMITH_LOCAL_USER_ID", "00000000-0000-0000-0000-000000000001"
)


def _is_postgres() -> bool:
    return op.get_bind().dialect.name == "postgresql"


def upgrade() -> None:
    # ── Create users table ───────────────────────────────────────────
    op.create_table(
        "users",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("apple_sub", sa.String(255), unique=True, nullable=True),
        sa.Column("google_sub", sa.String(255), unique=True, nullable=True),
        sa.Column("email", sa.String(255), nullable=False, server_default=""),
        sa.Column("display_name", sa.String(255), nullable=False, server_default=""),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False,
                  server_default=sa.func.now()),
    )

    # Seed a dev user for existing data
    op.execute(
        sa.text(
            "INSERT INTO users (id, email, display_name, created_at) "
            "VALUES (:id, 'dev@localhost', 'Dev User', CURRENT_TIMESTAMP)"
        ).bindparams(id=LOCAL_USER_ID)
    )

    # ── Add nullable user_id to user-owned tables ────────────────────
    user_owned = [
        "weeks", "recipes", "assistant_threads", "ai_runs",
        "staples", "preference_signals", "ingredient_preferences",
        "profile_settings",
    ]
    for table in user_owned:
        op.add_column(table, sa.Column("user_id", sa.String(36), nullable=True))

    # Backfill
    for table in user_owned:
        op.execute(
            sa.text(f"UPDATE {table} SET user_id = :uid WHERE user_id IS NULL")  # noqa: S608
            .bindparams(uid=LOCAL_USER_ID)
        )

    if _is_postgres():
        _upgrade_postgres()
    else:
        _upgrade_sqlite()


def _upgrade_postgres() -> None:
    """Postgres: use ALTER TABLE directly — supports named constraint ops."""

    # weeks: make NOT NULL, drop unique index, add composite unique
    op.alter_column("weeks", "user_id", nullable=False)
    op.drop_index("ix_weeks_week_start", table_name="weeks")
    op.create_unique_constraint("uq_weeks_user_week_start", "weeks", ["user_id", "week_start"])
    op.create_index("ix_weeks_week_start", "weeks", ["week_start"])  # keep non-unique for date lookups
    op.create_index("ix_weeks_user_created", "weeks", ["user_id", "created_at"])

    # recipes, assistant_threads, ai_runs: NOT NULL + index
    for table in ["recipes", "assistant_threads", "ai_runs"]:
        op.alter_column(table, "user_id", nullable=False)
        op.create_index(f"ix_{table}_user_created", table, ["user_id", "created_at"])

    # staples: NOT NULL, drop unique index, add composite
    op.alter_column("staples", "user_id", nullable=False)
    op.drop_index("ix_staples_normalized_name", table_name="staples")
    op.create_unique_constraint("uq_staples_user_normalized_name", "staples", ["user_id", "normalized_name"])
    op.create_index("ix_staples_normalized_name", "staples", ["normalized_name"])  # keep non-unique

    # profile_settings: NOT NULL, change PK
    op.alter_column("profile_settings", "user_id", nullable=False)
    op.drop_constraint("profile_settings_pkey", "profile_settings", type_="primary")
    op.create_primary_key("profile_settings_pkey", "profile_settings", ["user_id", "key"])

    # preference_signals: NOT NULL, swap constraint
    op.alter_column("preference_signals", "user_id", nullable=False)
    op.drop_constraint("uq_signal_type_name", "preference_signals", type_="unique")
    op.create_unique_constraint(
        "uq_preference_signals_user_type_name", "preference_signals",
        ["user_id", "signal_type", "normalized_name"],
    )

    # ingredient_preferences: NOT NULL, swap constraint
    op.alter_column("ingredient_preferences", "user_id", nullable=False)
    op.drop_constraint("uq_ingredient_preference_base", "ingredient_preferences", type_="unique")
    op.create_unique_constraint(
        "uq_ingredient_preferences_user_base", "ingredient_preferences",
        ["user_id", "base_ingredient_id"],
    )


def _upgrade_sqlite() -> None:
    """SQLite: manual table recreation for inline UNIQUE constraints."""

    # weeks
    op.execute(sa.text("""
        CREATE TABLE weeks_new (
            id VARCHAR(36) NOT NULL PRIMARY KEY,
            user_id VARCHAR(36) NOT NULL,
            week_start DATE NOT NULL,
            week_end DATE NOT NULL,
            status VARCHAR(32) NOT NULL DEFAULT 'staging',
            notes TEXT NOT NULL DEFAULT '',
            ready_for_ai_at TIMESTAMP,
            approved_at TIMESTAMP,
            priced_at TIMESTAMP,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL,
            UNIQUE (user_id, week_start)
        )
    """))
    op.execute(sa.text("""
        INSERT INTO weeks_new
        SELECT id, user_id, week_start, week_end, status, notes,
               ready_for_ai_at, approved_at, priced_at, created_at, updated_at
        FROM weeks
    """))
    op.drop_table("weeks")
    op.rename_table("weeks_new", "weeks")
    op.create_index("ix_weeks_week_start", "weeks", ["week_start"])
    op.create_index("ix_weeks_user_created", "weeks", ["user_id", "created_at"])

    # staples
    op.execute(sa.text("""
        CREATE TABLE staples_new (
            id VARCHAR(36) NOT NULL PRIMARY KEY,
            user_id VARCHAR(36) NOT NULL,
            staple_name VARCHAR(255) NOT NULL,
            normalized_name VARCHAR(255) NOT NULL,
            notes TEXT NOT NULL DEFAULT '',
            is_active BOOLEAN NOT NULL DEFAULT TRUE,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL,
            UNIQUE (user_id, normalized_name)
        )
    """))
    op.execute(sa.text("""
        INSERT INTO staples_new
        SELECT id, user_id, staple_name, normalized_name, notes,
               is_active, created_at, updated_at
        FROM staples
    """))
    op.drop_table("staples")
    op.rename_table("staples_new", "staples")
    op.create_index("ix_staples_normalized_name", "staples", ["normalized_name"])

    # profile_settings
    op.execute(sa.text("""
        CREATE TABLE profile_settings_new (
            user_id VARCHAR(36) NOT NULL,
            key VARCHAR(80) NOT NULL,
            value TEXT NOT NULL DEFAULT '',
            updated_at TIMESTAMP NOT NULL,
            PRIMARY KEY (user_id, key)
        )
    """))
    op.execute(sa.text("""
        INSERT INTO profile_settings_new (user_id, key, value, updated_at)
        SELECT user_id, key, value, updated_at FROM profile_settings
    """))
    op.drop_table("profile_settings")
    op.rename_table("profile_settings_new", "profile_settings")

    # Simple tables
    for table in ["recipes", "assistant_threads", "ai_runs"]:
        with op.batch_alter_table(table, recreate="always") as batch_op:
            batch_op.alter_column("user_id", existing_type=sa.String(36), nullable=False)
            batch_op.create_index(f"ix_{table}_user_created", ["user_id", "created_at"])

    # preference_signals
    with op.batch_alter_table("preference_signals", recreate="always") as batch_op:
        batch_op.alter_column("user_id", existing_type=sa.String(36), nullable=False)
        batch_op.drop_constraint("uq_signal_type_name", type_="unique")
        batch_op.create_unique_constraint(
            "uq_preference_signals_user_type_name",
            ["user_id", "signal_type", "normalized_name"],
        )

    # ingredient_preferences
    with op.batch_alter_table("ingredient_preferences", recreate="always") as batch_op:
        batch_op.alter_column("user_id", existing_type=sa.String(36), nullable=False)
        batch_op.drop_constraint("uq_ingredient_preference_base", type_="unique")
        batch_op.create_unique_constraint(
            "uq_ingredient_preferences_user_base",
            ["user_id", "base_ingredient_id"],
        )


def downgrade() -> None:
    if _is_postgres():
        _downgrade_postgres()
    else:
        _downgrade_sqlite()
    op.drop_table("users")


def _downgrade_postgres() -> None:
    # ingredient_preferences
    op.drop_constraint("uq_ingredient_preferences_user_base", "ingredient_preferences", type_="unique")
    op.create_unique_constraint("uq_ingredient_preference_base", "ingredient_preferences", ["base_ingredient_id"])
    op.drop_column("ingredient_preferences", "user_id")

    # preference_signals
    op.drop_constraint("uq_preference_signals_user_type_name", "preference_signals", type_="unique")
    op.create_unique_constraint("uq_signal_type_name", "preference_signals", ["signal_type", "normalized_name"])
    op.drop_column("preference_signals", "user_id")

    # profile_settings
    op.drop_constraint("profile_settings_pkey", "profile_settings", type_="primary")
    op.create_primary_key("profile_settings_pkey", "profile_settings", ["key"])
    op.drop_column("profile_settings", "user_id")

    # staples
    op.drop_constraint("uq_staples_user_normalized_name", "staples", type_="unique")
    op.drop_index("ix_staples_normalized_name", table_name="staples")
    op.create_index("ix_staples_normalized_name", "staples", ["normalized_name"], unique=True)
    op.drop_column("staples", "user_id")

    # Simple tables
    for table in ["ai_runs", "assistant_threads", "recipes"]:
        op.drop_index(f"ix_{table}_user_created", table_name=table)
        op.drop_column(table, "user_id")

    # weeks
    op.drop_index("ix_weeks_user_created", table_name="weeks")
    op.drop_constraint("uq_weeks_user_week_start", "weeks", type_="unique")
    op.drop_index("ix_weeks_week_start", table_name="weeks")
    op.create_index("ix_weeks_week_start", "weeks", ["week_start"], unique=True)
    op.drop_column("weeks", "user_id")


def _downgrade_sqlite() -> None:
    # ingredient_preferences
    with op.batch_alter_table("ingredient_preferences", recreate="always") as batch_op:
        batch_op.drop_constraint("uq_ingredient_preferences_user_base", type_="unique")
        batch_op.create_unique_constraint("uq_ingredient_preference_base", ["base_ingredient_id"])
        batch_op.drop_column("user_id")

    # preference_signals
    with op.batch_alter_table("preference_signals", recreate="always") as batch_op:
        batch_op.drop_constraint("uq_preference_signals_user_type_name", type_="unique")
        batch_op.create_unique_constraint("uq_signal_type_name", ["signal_type", "normalized_name"])
        batch_op.drop_column("user_id")

    # Simple tables
    for table in ["ai_runs", "assistant_threads", "recipes"]:
        with op.batch_alter_table(table, recreate="always") as batch_op:
            batch_op.drop_index(f"ix_{table}_user_created")
            batch_op.drop_column("user_id")

    # profile_settings
    op.execute(sa.text("""
        CREATE TABLE profile_settings_old (
            key VARCHAR(80) NOT NULL PRIMARY KEY,
            value TEXT NOT NULL DEFAULT '',
            updated_at TIMESTAMP NOT NULL
        )
    """))
    op.execute(sa.text("INSERT INTO profile_settings_old SELECT key, value, updated_at FROM profile_settings"))
    op.drop_table("profile_settings")
    op.rename_table("profile_settings_old", "profile_settings")

    # staples
    op.execute(sa.text("""
        CREATE TABLE staples_old (
            id VARCHAR(36) NOT NULL PRIMARY KEY, staple_name VARCHAR(255) NOT NULL,
            normalized_name VARCHAR(255) NOT NULL UNIQUE, notes TEXT NOT NULL DEFAULT '',
            is_active BOOLEAN NOT NULL DEFAULT TRUE, created_at TIMESTAMP NOT NULL, updated_at TIMESTAMP NOT NULL
        )
    """))
    op.execute(sa.text("INSERT INTO staples_old SELECT id, staple_name, normalized_name, notes, is_active, created_at, updated_at FROM staples"))
    op.drop_table("staples")
    op.rename_table("staples_old", "staples")
    op.create_index("ix_staples_normalized_name", "staples", ["normalized_name"])

    # weeks
    op.execute(sa.text("""
        CREATE TABLE weeks_old (
            id VARCHAR(36) NOT NULL PRIMARY KEY, week_start DATE NOT NULL UNIQUE,
            week_end DATE NOT NULL, status VARCHAR(32) NOT NULL DEFAULT 'staging',
            notes TEXT NOT NULL DEFAULT '', ready_for_ai_at TIMESTAMP, approved_at TIMESTAMP,
            priced_at TIMESTAMP, created_at TIMESTAMP NOT NULL, updated_at TIMESTAMP NOT NULL
        )
    """))
    op.execute(sa.text("""
        INSERT INTO weeks_old SELECT id, week_start, week_end, status, notes,
        ready_for_ai_at, approved_at, priced_at, created_at, updated_at FROM weeks
    """))
    op.drop_table("weeks")
    op.rename_table("weeks_old", "weeks")
    op.create_index("ix_weeks_week_start", "weeks", ["week_start"])
