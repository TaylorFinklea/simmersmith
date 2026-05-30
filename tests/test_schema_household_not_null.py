"""F20 regression: household_id must be NOT NULL on the multi-tenant root
tables (the DB-level guarantee, matching the ORM models)."""
from __future__ import annotations

from sqlalchemy import inspect

from app.db import session_scope


def test_household_id_not_null_on_shared_tables() -> None:
    with session_scope() as session:
        insp = inspect(session.get_bind())
        for table in ("weeks", "recipes", "staples", "events", "guests"):
            cols = {c["name"]: c for c in insp.get_columns(table)}
            assert "household_id" in cols, f"{table} missing household_id"
            assert cols["household_id"]["nullable"] is False, (
                f"{table}.household_id should be NOT NULL"
            )
