"""Regression coverage for Build 103: iOS "swap meal" between days/slots.

Two layers:

1. **Model declaration** — the ``uq_week_day_slot`` UniqueConstraint must
   be DEFERRABLE INITIALLY DEFERRED so Postgres delays the check to
   commit-time. Runs on any backend.

2. **End-to-end swap** — exchange ``(day_name, slot)`` between two
   existing meals in one PUT and assert the endpoint returns 200, not
   500. Skipped on SQLite (the default test DB) because SQLite parses
   but does not honour DEFERRABLE on UNIQUE constraints — only Postgres
   exhibits the deferred behaviour we're testing.
"""
from __future__ import annotations

import os

import pytest

from app.models import WeekMeal


def test_uq_week_day_slot_is_deferred() -> None:
    constraints = [
        c
        for c in WeekMeal.__table__.constraints
        if getattr(c, "name", None) == "uq_week_day_slot"
    ]
    assert len(constraints) == 1, (
        f"Expected one uq_week_day_slot constraint, found {len(constraints)}"
    )
    constraint = constraints[0]
    assert constraint.deferrable is True, "uq_week_day_slot must be DEFERRABLE"
    assert constraint.initially == "DEFERRED", (
        "uq_week_day_slot must be INITIALLY DEFERRED"
    )


@pytest.mark.skipif(
    "sqlite" in os.environ.get("SIMMERSMITH_DATABASE_URL", "sqlite"),
    reason=(
        "SQLite does not honour DEFERRABLE on UNIQUE constraints; "
        "this assertion is meaningful only against Postgres."
    ),
)
def test_swap_meals_between_slots_does_not_500(client) -> None:
    """Reproduces the user-reported HTTP 500: two meals exchange
    ``(day_name, slot)`` in a single PUT, mirroring the iOS drag-to-swap
    interaction. Pre-fix, ``update_week_meals`` flushed two UPDATEs and
    the first one tripped ``uq_week_day_slot`` on Postgres."""
    create = client.post("/api/weeks", json={"week_start": "2026-04-20"})
    assert create.status_code == 200, create.text
    week_id = create.json()["week_id"]

    seed = client.put(
        f"/api/weeks/{week_id}/meals",
        json=[
            {
                "day_name": "Monday",
                "meal_date": "2026-04-20",
                "slot": "dinner",
                "recipe_name": "Tacos",
            },
            {
                "day_name": "Tuesday",
                "meal_date": "2026-04-21",
                "slot": "dinner",
                "recipe_name": "Pasta",
            },
        ],
    )
    assert seed.status_code == 200, seed.text
    meals = {m["recipe_name"]: m for m in seed.json()["meals"]}
    tacos_id = meals["Tacos"]["meal_id"]
    pasta_id = meals["Pasta"]["meal_id"]

    swap = client.put(
        f"/api/weeks/{week_id}/meals",
        json=[
            {
                "meal_id": tacos_id,
                "day_name": "Tuesday",
                "meal_date": "2026-04-21",
                "slot": "dinner",
                "recipe_name": "Tacos",
            },
            {
                "meal_id": pasta_id,
                "day_name": "Monday",
                "meal_date": "2026-04-20",
                "slot": "dinner",
                "recipe_name": "Pasta",
            },
        ],
    )
    assert swap.status_code == 200, swap.text
    by_id = {m["meal_id"]: m for m in swap.json()["meals"]}
    assert by_id[tacos_id]["day_name"] == "Tuesday"
    assert by_id[pasta_id]["day_name"] == "Monday"
