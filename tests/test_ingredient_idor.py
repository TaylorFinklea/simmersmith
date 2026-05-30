"""F26/F27 regression: a household cannot mutate ANOTHER household's
private (household_only) ingredient via the catalog routes.

The global approved catalog stays collaboratively editable by design
(covered by test_ingredient_catalog_merge_and_archive_routes); this guards
only the cross-tenant private-row case.
"""
from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models import User
from app.models._base import utcnow
from app.services.households import create_solo_household

USER_A = "a1a1a1a1-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
USER_B = "b2b2b2b2-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
SECRET = "test-ingredient-idor-secret"


@pytest.fixture(autouse=True)
def _auth_users():
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


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def test_cannot_archive_other_households_private_ingredient(client: TestClient) -> None:
    created = client.post(
        "/api/ingredients",
        json={"name": "A's Secret Spice Blend", "category": "Spices"},
        headers=_h(USER_A),
    )
    assert created.status_code == 200, created.text
    ing_id = created.json()["base_ingredient_id"]

    # B can't see it (private) and can't archive it.
    assert client.post(f"/api/ingredients/{ing_id}/archive", headers=_h(USER_B)).status_code == 404
    # ...but the owner can.
    assert client.post(f"/api/ingredients/{ing_id}/archive", headers=_h(USER_A)).status_code == 200


def test_cannot_merge_other_households_private_ingredient(client: TestClient) -> None:
    a_ing = client.post(
        "/api/ingredients",
        json={"name": "A Private Source", "category": "Spices"},
        headers=_h(USER_A),
    ).json()["base_ingredient_id"]
    b_ing = client.post(
        "/api/ingredients",
        json={"name": "B Private Target", "category": "Spices"},
        headers=_h(USER_B),
    ).json()["base_ingredient_id"]

    # B tries to merge A's private row into B's row — must be rejected.
    resp = client.post(
        f"/api/ingredients/{a_ing}/merge",
        json={"target_id": b_ing},
        headers=_h(USER_B),
    )
    assert resp.status_code == 404, resp.text
