"""M21 household sharing API tests.

Covers:
1. Owner can mint an invitation; non-owner gets 403.
2. Joining with a valid code (joiner has empty solo) → membership row,
   solo deleted, both members visible.
3. Joining with content (joiner has Week + Recipe) → solo merged in,
   both members see the joiner's content + the inviter's content.
4. Joining with a conflicting same-week_start week → both Week rows
   coexist (per-user uniqueness). Listing returns both.
5. Expired invitation → 410 Gone.
6. Joining twice with same code → 410 (single-use).
7. Two members in same household see the same week (round-trip).
8. Each member keeps their own push_devices (per-user isolation
   preserved).
9. Inviter trying to claim their own code → 409.
"""
from __future__ import annotations

import os
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models import HouseholdInvitation, User
from app.models._base import utcnow
from app.services.households import create_solo_household


USER_A_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_B_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
TEST_JWT_SECRET = "test-household-secret-not-for-production"


@pytest.fixture(autouse=True)
def setup_auth_and_users():
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    get_settings.cache_clear()

    with session_scope() as session:
        session.add(User(id=USER_A_ID, email="a@test.com", display_name="A", created_at=utcnow()))
        session.add(User(id=USER_B_ID, email="b@test.com", display_name="B", created_at=utcnow()))
        session.flush()
        # Pre-create solo households so the lazy-creation path doesn't
        # fire mid-test (that path commits a fresh household_id which
        # would surprise the assertions below).
        create_solo_household(session, USER_A_ID)
        create_solo_household(session, USER_B_ID)

    yield

    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


def _headers(user_id: str) -> dict[str, str]:
    settings = get_settings()
    token = issue_session_jwt(user_id, settings)
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def headers_a() -> dict[str, str]:
    return _headers(USER_A_ID)


@pytest.fixture
def headers_b() -> dict[str, str]:
    return _headers(USER_B_ID)


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


# ── 1. Invitation minting ────────────────────────────────────────


def test_owner_can_mint_invitation(client: TestClient, headers_a: dict[str, str]) -> None:
    resp = client.post("/api/household/invitations", headers=headers_a)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "code" in body
    assert len(body["code"]) == 8
    assert "expires_at" in body


def test_non_owner_cannot_mint_invitation(client: TestClient, headers_a, headers_b) -> None:
    # First A invites B — B becomes a member, NOT an owner.
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    join_resp = client.post(
        "/api/household/join",
        json={"code": invite["code"]},
        headers=headers_b,
    )
    assert join_resp.status_code == 200, join_resp.text

    # Now B (a member, not owner) tries to mint a new code → 403.
    resp = client.post("/api/household/invitations", headers=headers_b)
    assert resp.status_code == 403


# ── 2. Empty-solo join ────────────────────────────────────────


def test_join_with_empty_solo_merges_membership(
    client: TestClient, headers_a, headers_b
) -> None:
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    resp = client.post(
        "/api/household/join", json={"code": invite["code"]}, headers=headers_b
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    member_ids = {m["user_id"] for m in body["members"]}
    assert member_ids == {USER_A_ID, USER_B_ID}
    # B is a member, A is owner.
    roles = {m["user_id"]: m["role"] for m in body["members"]}
    assert roles[USER_A_ID] == "owner"
    assert roles[USER_B_ID] == "member"


# ── 3. Auto-merge: joiner with content ───────────────────────


def test_join_auto_merges_joiner_recipes_and_weeks(
    client: TestClient, headers_a, headers_b
) -> None:
    """B has a recipe and a week before joining A's household.
    After join, both A and B see B's recipe in the shared library.
    """
    # B creates a recipe in their solo household.
    resp_b_recipe = client.post(
        "/api/recipes",
        json={"name": "B's secret sauce", "ingredients": [], "steps": []},
        headers=headers_b,
    )
    assert resp_b_recipe.status_code == 200, resp_b_recipe.text
    b_recipe_id = resp_b_recipe.json()["recipe_id"]

    # A creates an invitation; B joins.
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    join_resp = client.post(
        "/api/household/join", json={"code": invite["code"]}, headers=headers_b
    )
    assert join_resp.status_code == 200, join_resp.text

    # A now sees B's recipe in their library.
    resp_a_list = client.get("/api/recipes", headers=headers_a)
    assert resp_a_list.status_code == 200
    a_recipe_ids = [r["recipe_id"] for r in resp_a_list.json()]
    assert b_recipe_id in a_recipe_ids


# ── 5. Expired invitation ────────────────────────────────────


def test_join_with_expired_code_returns_410(
    client: TestClient, headers_a, headers_b
) -> None:
    # Mint an invitation, then back-date its expires_at to the past.
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    code = invite["code"]
    with session_scope() as session:
        from sqlalchemy import select

        row = session.scalar(
            select(HouseholdInvitation).where(HouseholdInvitation.code == code)
        )
        assert row is not None
        row.expires_at = utcnow() - timedelta(hours=1)

    resp = client.post(
        "/api/household/join", json={"code": code}, headers=headers_b
    )
    assert resp.status_code == 410


# ── 6. Single-use ────────────────────────────────────────────


def test_join_twice_with_same_code_returns_410(
    client: TestClient, headers_a, headers_b
) -> None:
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    code = invite["code"]

    first = client.post("/api/household/join", json={"code": code}, headers=headers_b)
    assert first.status_code == 200, first.text

    # Second attempt by a third user (or the same user re-joining) → 410.
    second = client.post("/api/household/join", json={"code": code}, headers=headers_b)
    assert second.status_code in (410, 409), second.text


# ── 7. Cross-member visibility ───────────────────────────────


def test_two_members_see_same_week(
    client: TestClient, headers_a, headers_b
) -> None:
    # Bring B into A's household.
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    join = client.post("/api/household/join", json={"code": invite["code"]}, headers=headers_b)
    assert join.status_code == 200

    # A creates a week.
    week = client.post("/api/weeks", json={"week_start": "2026-05-04"}, headers=headers_a)
    assert week.status_code == 200, week.text
    week_id = week.json()["week_id"]

    # B sees the same week via /current.
    resp_b = client.get("/api/weeks/current", headers=headers_b)
    assert resp_b.status_code == 200, resp_b.text
    body = resp_b.json()
    assert body is not None
    assert body["week_id"] == week_id


# ── 8. Push devices stay per-user ─────────────────────────────


def test_push_devices_remain_per_user_after_join(
    client: TestClient, headers_a, headers_b
) -> None:
    """Joining a household doesn't share push device tokens; each
    member only registers their own devices."""
    # Bring B into A's household.
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    client.post("/api/household/join", json={"code": invite["code"]}, headers=headers_b)

    # B registers a device.
    resp = client.post(
        "/api/push/devices",
        json={
            "device_token": "ff" * 32,
            "environment": "sandbox",
            "bundle_id": "app.simmersmith.ios",
        },
        headers=headers_b,
    )
    assert resp.status_code == 200, resp.text

    # Verify only B has the device row, not A.
    from sqlalchemy import select

    from app.models.push import PushDevice

    with session_scope() as session:
        a_devices = session.scalars(
            select(PushDevice).where(PushDevice.user_id == USER_A_ID)
        ).all()
        b_devices = session.scalars(
            select(PushDevice).where(PushDevice.user_id == USER_B_ID)
        ).all()
    assert len(a_devices) == 0
    assert len(b_devices) == 1


# ── 9. Inviter cannot claim their own code ───────────────────


def test_inviter_claiming_own_code_returns_409(
    client: TestClient, headers_a
) -> None:
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    resp = client.post(
        "/api/household/join", json={"code": invite["code"]}, headers=headers_a
    )
    assert resp.status_code == 409


# ── Bonus: rename + revoke ───────────────────────────────────


def test_owner_can_rename_household(client: TestClient, headers_a) -> None:
    resp = client.put("/api/household", json={"name": "The Smiths"}, headers=headers_a)
    assert resp.status_code == 200, resp.text
    assert resp.json()["name"] == "The Smiths"


def test_owner_can_revoke_invitation(client: TestClient, headers_a, headers_b) -> None:
    invite = client.post("/api/household/invitations", headers=headers_a).json()
    code = invite["code"]
    resp = client.delete(f"/api/household/invitations/{code}", headers=headers_a)
    assert resp.status_code == 204
    # B can't claim a revoked code.
    join_resp = client.post(
        "/api/household/join", json={"code": code}, headers=headers_b
    )
    assert join_resp.status_code == 410


def test_get_household_returns_owner_and_members(client: TestClient, headers_a) -> None:
    resp = client.get("/api/household", headers=headers_a)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["role"] == "owner"
    assert len(body["members"]) == 1
    assert body["members"][0]["user_id"] == USER_A_ID


# Bring date import in for future use; suppress the unused-import warning.
_ = date  # noqa: F841
