"""Catalog-lane regressions from the 2026-06-13 bug-bash.

Each test maps to a confirmed finding in
.docs/ai/phases/bugbash-2026-06-13-report.md:

- #6  resolve_ingredient_route never commits → minted base id is rolled back
- #7  merge_base_ingredients migrates only ONE preference row, orphaning the rest
- #22 choice_for_base_ingredient returns archived/inactive preferred variations
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
from app.models import BaseIngredient, IngredientPreference, User
from app.models._base import utcnow
from app.services.households import create_solo_household
from app.services.ingredient_catalog import (
    archive_variation,
    choice_for_base_ingredient,
    create_or_update_variation,
    ensure_base_ingredient,
    merge_base_ingredients,
    upsert_ingredient_preference,
)

USER_A = "ca1a1a1a-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
SECRET = "test-batch-catalog-secret"


# ── #6 — resolve route commits a freshly-minted base ─────────────────


@pytest.fixture
def _auth_user():
    os.environ["SIMMERSMITH_JWT_SECRET"] = SECRET
    get_settings.cache_clear()
    with session_scope() as session:
        session.add(User(id=USER_A, email="a@t.com", display_name="A", created_at=utcnow()))
        session.flush()
        create_solo_household(session, USER_A)
    yield
    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


def _h(uid: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {issue_session_jwt(uid, get_settings())}"}


def _select_prefs(base_ingredient_id: str):
    return select(IngredientPreference).where(
        IngredientPreference.base_ingredient_id == base_ingredient_id
    )


@pytest.fixture
def jwt_client():
    with TestClient(app) as c:
        yield c


def test_resolve_route_persists_minted_base_ingredient(_auth_user, jwt_client: TestClient) -> None:
    # A name with no catalog match forces resolve_ingredient to mint a base.
    resp = jwt_client.post(
        "/api/ingredients/resolve",
        json={"ingredient_name": "dragon fruit puree"},
        headers=_h(USER_A),
    )
    assert resp.status_code == 200, resp.text
    base_id = resp.json()["base_ingredient_id"]
    assert base_id, "expected a freshly-minted base_ingredient_id"

    # The mint was committed (not rolled back at session.close), so a later
    # request in a fresh session must still find the row.
    with session_scope() as session:
        assert session.get(BaseIngredient, base_id) is not None


# ── #7 — merge migrates ALL source preferences ──────────────────────


def test_merge_base_ingredients_migrates_all_preferences() -> None:
    with session_scope() as session:
        source = ensure_base_ingredient(session, name="Ketchup Dup")
        target = ensure_base_ingredient(session, name="Ketchup")
        # One user with two ranks on the source base.
        upsert_ingredient_preference(
            session, "user-a", base_ingredient_id=source.id, preferred_brand="Heinz", rank=1
        )
        upsert_ingredient_preference(
            session, "user-a", base_ingredient_id=source.id, preferred_brand="Hunts", rank=2
        )
        # A second user with their own preference on the source base.
        upsert_ingredient_preference(
            session, "user-b", base_ingredient_id=source.id, preferred_brand="Annies", rank=1
        )
        session.flush()

        merge_base_ingredients(session, source_id=source.id, target_id=target.id)
        session.flush()

        # Nothing left dangling on the archived source.
        orphans = session.scalars(_select_prefs(source.id)).all()
        assert orphans == [], "all source preferences must be migrated off the archived base"

        moved = session.scalars(_select_prefs(target.id)).all()
        moved_keys = {(p.user_id, p.rank, p.preferred_brand) for p in moved}
        assert moved_keys == {
            ("user-a", 1, "Heinz"),
            ("user-a", 2, "Hunts"),
            ("user-b", 1, "Annies"),
        }


def test_merge_base_ingredients_guards_rank_collision() -> None:
    with session_scope() as session:
        source = ensure_base_ingredient(session, name="Mustard Dup")
        target = ensure_base_ingredient(session, name="Mustard")
        # Same (user, rank) exists on both bases — target's is empty so the
        # source's non-empty fields should fill it without a unique violation.
        upsert_ingredient_preference(
            session, "user-a", base_ingredient_id=target.id, preferred_brand="", rank=1
        )
        upsert_ingredient_preference(
            session, "user-a", base_ingredient_id=source.id, preferred_brand="Frenchs", rank=1
        )
        session.flush()

        merge_base_ingredients(session, source_id=source.id, target_id=target.id)
        session.flush()

        assert session.scalars(_select_prefs(source.id)).all() == []
        merged = session.scalars(_select_prefs(target.id)).all()
        assert len(merged) == 1
        assert merged[0].preferred_brand == "Frenchs"


# ── #22 — archived preferred variation is not chosen ────────────────


def test_choice_drops_archived_preferred_variation_by_id() -> None:
    with session_scope() as session:
        base = ensure_base_ingredient(session, name="Ketchup Pref")
        variation = create_or_update_variation(
            session, base_ingredient_id=base.id, name="Heinz 32oz", brand="Heinz"
        )
        upsert_ingredient_preference(
            session,
            "user-a",
            base_ingredient_id=base.id,
            preferred_variation_id=variation.id,
        )
        session.flush()

        # While active, the preferred variation is the chosen product.
        _, chosen, _status = choice_for_base_ingredient(
            session,
            user_id="user-a",
            base_ingredient_id=base.id,
            recipe_variation_id=None,
            recipe_resolution_status="",
        )
        assert chosen is not None and chosen.id == variation.id

        # After archiving, it must NOT be returned into the grocery list.
        archive_variation(session, variation.id)
        session.flush()
        _, chosen_after, _status_after = choice_for_base_ingredient(
            session,
            user_id="user-a",
            base_ingredient_id=base.id,
            recipe_variation_id=None,
            recipe_resolution_status="",
        )
        assert chosen_after is None


def test_choice_drops_archived_preferred_variation_by_brand() -> None:
    with session_scope() as session:
        base = ensure_base_ingredient(session, name="Mustard Pref")
        variation = create_or_update_variation(
            session, base_ingredient_id=base.id, name="Frenchs Classic", brand="Frenchs"
        )
        upsert_ingredient_preference(
            session,
            "user-a",
            base_ingredient_id=base.id,
            preferred_brand="Frenchs",
        )
        session.flush()

        archive_variation(session, variation.id)
        session.flush()
        _, chosen, _status = choice_for_base_ingredient(
            session,
            user_id="user-a",
            base_ingredient_id=base.id,
            recipe_variation_id=None,
            recipe_resolution_status="",
        )
        assert chosen is None
