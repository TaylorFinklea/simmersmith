"""M63/M64/M8: catalog-write scoping.

- M63: a household-driven resolution mints a HOUSEHOLD-PRIVATE base
  ingredient, not a global `approved` row (no unreviewed pollution of the
  shared master list). Existing global rows are still reused.
- M64: a `persist=False` preview resolution never mints a row.
- M8: the nutrition estimate can't return another household's private
  reference values by id.
"""
from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models import BaseIngredient, User
from app.models._base import utcnow
from app.services.households import create_solo_household
from app.services.ingredient_catalog import resolve_ingredient
from app.services.ingredient_catalog.shared import normalize_name

NOVEL = "Quixotic Zzyzx Powder"
NOVEL_NORM = normalize_name(NOVEL)


def _base_rows(session, normalized: str):
    return list(
        session.scalars(
            select(BaseIngredient).where(BaseIngredient.normalized_name == normalized)
        ).all()
    )


def test_preview_resolution_does_not_mint() -> None:
    """persist=False resolves against existing rows only — a novel
    ingredient comes back unresolved and no catalog row is written (M64)."""
    with session_scope() as session:
        result = resolve_ingredient(session, ingredient_name=NOVEL, persist=False)
        assert result.base_ingredient_id is None
        assert result.resolution_status == "unresolved"
        assert _base_rows(session, NOVEL_NORM) == []


def test_household_resolution_mints_private_row() -> None:
    """A household-scoped resolution mints a household_only row (M63)."""
    with session_scope() as session:
        hh = create_solo_household(session, "user-hh-1")
        result = resolve_ingredient(session, ingredient_name=NOVEL, household_id=hh)
        assert result.base_ingredient_id is not None
        rows = _base_rows(session, NOVEL_NORM)
        assert len(rows) == 1
        assert rows[0].household_id == hh
        assert rows[0].submission_status == "household_only"


def test_system_resolution_stays_global() -> None:
    """No household_id (seed/system path) keeps the global approved
    behavior, so the seeded catalog isn't disturbed."""
    with session_scope() as session:
        result = resolve_ingredient(session, ingredient_name=NOVEL)
        assert result.base_ingredient_id is not None
        rows = _base_rows(session, NOVEL_NORM)
        assert len(rows) == 1
        assert rows[0].household_id is None
        assert rows[0].submission_status == "approved"


def test_household_resolution_reuses_global_approved() -> None:
    """A pre-existing global approved row is reused, not duplicated into a
    household-private copy — common ingredients stay shared."""
    with session_scope() as session:
        hh = create_solo_household(session, "user-hh-2")
        # System mints the global approved row first.
        global_id = resolve_ingredient(session, ingredient_name=NOVEL).base_ingredient_id
        # Household resolution should adopt it, not mint a private duplicate.
        reused = resolve_ingredient(session, ingredient_name=NOVEL, household_id=hh)
        assert reused.base_ingredient_id == global_id
        assert len(_base_rows(session, NOVEL_NORM)) == 1


# ── M8: nutrition estimate can't probe another household's private ref ──

USER_A = "a1a1a1a1-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
USER_B = "b2b2b2b2-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
SECRET = "test-catalog-scoping-secret"


@pytest.fixture
def two_households():
    os.environ["SIMMERSMITH_JWT_SECRET"] = SECRET
    get_settings.cache_clear()
    with session_scope() as session:
        session.add(User(id=USER_A, email="a@t.com", display_name="A", created_at=utcnow()))
        session.add(User(id=USER_B, email="b@t.com", display_name="B", created_at=utcnow()))
        session.flush()
        create_solo_household(session, USER_A)
        create_solo_household(session, USER_B)
    yield
    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


def _h(uid: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {issue_session_jwt(uid, get_settings())}"}


def test_nutrition_estimate_ignores_other_household_private_ref(two_households) -> None:  # noqa: ARG001
    with TestClient(app) as client:
        # A creates a private base ingredient with a distinctive calorie value.
        created = client.post(
            "/api/ingredients",
            json={
                "name": "A Private Caloric Blend",
                "category": "Spices",
                "nutrition_reference_amount": 100,
                "nutrition_reference_unit": "g",
                "calories": 9999,
            },
            headers=_h(USER_A),
        )
        assert created.status_code == 200, created.text
        a_base_id = created.json()["base_ingredient_id"]

        # B passes A's private base id into the nutrition estimate. The
        # private ref must be ignored (nulled) — its 9999 cal must not leak.
        resp = client.post(
            "/api/recipes/nutrition/estimate",
            json={
                "name": "Probe",
                "servings": 1,
                "ingredients": [
                    {
                        "ingredient_name": "mystery",
                        "base_ingredient_id": a_base_id,
                        "quantity": 100,
                        "unit": "g",
                    }
                ],
                "steps": [],
            },
            headers=_h(USER_B),
        )
        assert resp.status_code == 200, resp.text
        total = resp.json().get("total_calories")
        assert total != 9999
