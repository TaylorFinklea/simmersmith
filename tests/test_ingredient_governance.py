"""M25 Phase 2 — household-scoped ingredient catalog + governance.

Cases:
1. Household A creates an ingredient `household_only` → A's search
   finds it; B's does not.
2. A submits the ingredient → status flips; A still sees it, B
   doesn't.
3. Admin approves → status flips to `approved`, household_id clears,
   both A and B see it now.
4. Admin rejects → status flips, only A sees it (with reason in notes).
5. Two households can each have a private "Cherry tomato" without
   colliding (per-household partial unique).
6. POST /api/ingredients without auth → 401.
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


USER_A_ID = "aaaaa-cat-aaa-1111-aaaaaaaaaaaa"
USER_B_ID = "bbbbb-cat-bbb-1111-bbbbbbbbbbbb"
TEST_JWT_SECRET = "test-catalog-governance-secret"
ADMIN_TOKEN = "test-admin-token-cat"


@pytest.fixture(autouse=True)
def setup_auth_and_users():
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    os.environ["SIMMERSMITH_API_TOKEN"] = ADMIN_TOKEN
    get_settings.cache_clear()

    with session_scope() as session:
        session.add(User(id=USER_A_ID, email="a@cat.com", display_name="A", created_at=utcnow()))
        session.add(User(id=USER_B_ID, email="b@cat.com", display_name="B", created_at=utcnow()))
        session.flush()
        create_solo_household(session, USER_A_ID)
        create_solo_household(session, USER_B_ID)

    yield

    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    os.environ.pop("SIMMERSMITH_API_TOKEN", None)
    get_settings.cache_clear()


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


def _headers(user_id: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {issue_session_jwt(user_id, get_settings())}"}


def _admin_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {ADMIN_TOKEN}"}


def _create(client: TestClient, user_id: str, *, name: str, status: str = "household_only") -> str:
    resp = client.post(
        "/api/ingredients",
        json={"name": name, "submission_status": status},
        headers=_headers(user_id),
    )
    assert resp.status_code == 200, resp.text
    return resp.json()["base_ingredient_id"]


def test_household_only_is_private_to_author(client: TestClient) -> None:
    ing_id = _create(client, USER_A_ID, name="Hotsauce 47")

    a_search = client.get("/api/ingredients?q=Hotsauce", headers=_headers(USER_A_ID)).json()
    b_search = client.get("/api/ingredients?q=Hotsauce", headers=_headers(USER_B_ID)).json()
    assert any(item["base_ingredient_id"] == ing_id for item in a_search)
    assert not any(item["base_ingredient_id"] == ing_id for item in b_search)


def test_submission_lifecycle(client: TestClient) -> None:
    ing_id = _create(client, USER_A_ID, name="Tonkotsu broth concentrate")

    submit = client.post(
        f"/api/ingredients/{ing_id}/submit",
        headers=_headers(USER_A_ID),
    )
    assert submit.status_code == 200
    assert submit.json()["submission_status"] == "submitted"

    # B still doesn't see it (status submitted, household-private).
    b_view = client.get("/api/ingredients?q=Tonkotsu", headers=_headers(USER_B_ID)).json()
    assert all(item["base_ingredient_id"] != ing_id for item in b_view)

    # Admin promotes.
    approve = client.post(
        f"/api/ingredients/{ing_id}/approve",
        headers=_admin_headers(),
    )
    assert approve.status_code == 200, approve.text
    body = approve.json()
    assert body["submission_status"] == "approved"
    assert body["household_id"] is None

    # Now everyone sees it.
    b_view = client.get("/api/ingredients?q=Tonkotsu", headers=_headers(USER_B_ID)).json()
    assert any(item["base_ingredient_id"] == ing_id for item in b_view)


def test_rejection_keeps_visibility_only_for_author(client: TestClient) -> None:
    ing_id = _create(client, USER_A_ID, name="Lapsang souchong tea")
    client.post(f"/api/ingredients/{ing_id}/submit", headers=_headers(USER_A_ID))

    reject = client.post(
        f"/api/ingredients/{ing_id}/reject?reason=Already%20covered%20by%20generic%20tea",
        headers=_admin_headers(),
    )
    assert reject.status_code == 200, reject.text
    body = reject.json()
    assert body["submission_status"] == "rejected"
    assert "[admin-rejected]" in body["notes"]

    a_view = client.get("/api/ingredients?q=Lapsang", headers=_headers(USER_A_ID)).json()
    b_view = client.get("/api/ingredients?q=Lapsang", headers=_headers(USER_B_ID)).json()
    assert any(item["base_ingredient_id"] == ing_id for item in a_view)
    assert not any(item["base_ingredient_id"] == ing_id for item in b_view)


def test_two_households_can_have_same_name(client: TestClient) -> None:
    # Use a name that is NOT in the seed catalog. If a global
    # approved row already exists for the same name, the
    # ensure_base_ingredient fall-through returns the canonical row
    # for both households (which is the right behavior — no point
    # privately duplicating salt/pepper/etc). Verify the partial-
    # uniqueness here using a name guaranteed to be uncatalogued.
    a_id = _create(client, USER_A_ID, name="Zorblum berry XYZ")
    b_id = _create(client, USER_B_ID, name="Zorblum berry XYZ")
    assert a_id != b_id

    a_view = client.get("/api/ingredients?q=Zorblum", headers=_headers(USER_A_ID)).json()
    b_view = client.get("/api/ingredients?q=Zorblum", headers=_headers(USER_B_ID)).json()
    assert any(item["base_ingredient_id"] == a_id for item in a_view)
    assert any(item["base_ingredient_id"] == b_id for item in b_view)
    # Cross-visibility blocked.
    assert all(item["base_ingredient_id"] != b_id for item in a_view)
    assert all(item["base_ingredient_id"] != a_id for item in b_view)


def test_post_without_auth_rejected(client: TestClient) -> None:
    resp = client.post("/api/ingredients", json={"name": "Anchovy paste"})
    assert resp.status_code in {401, 403}


def test_get_without_auth_rejected(client: TestClient) -> None:
    resp = client.get("/api/ingredients?q=anything")
    assert resp.status_code in {401, 403}


def test_only_author_can_submit(client: TestClient) -> None:
    ing_id = _create(client, USER_A_ID, name="Black truffle paste")
    resp = client.post(
        f"/api/ingredients/{ing_id}/submit", headers=_headers(USER_B_ID)
    )
    # B doesn't even see the row because the GET filter hides it; but
    # the submit route only checks ownership at the service layer, so
    # B gets a 400 (not 404). Either way it's rejected.
    assert resp.status_code in {400, 404}
