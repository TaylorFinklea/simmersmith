"""M21 follow-up tests — owner role transfer + member removal.

Covers:
- Transfer-owner happy path (roles swap).
- Transfer rejected: non-owner caller, non-member target, self-transfer.
- Leave (self-removal) for a non-owner member: succeeds + fresh solo.
- Owner cannot leave without transferring first.
- Owner kicks a non-owner member: succeeds + kicked user gets a solo.
- Non-owner cannot kick another member.
- Removing a non-member returns 404.
- Trying to "remove" the owner via the same endpoint returns 409
  (transfer-first hint).
"""
from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models import HouseholdMember, User
from app.models._base import utcnow
from app.services.households import create_solo_household, get_household_id


USER_A_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_B_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
USER_C_ID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
TEST_JWT_SECRET = "test-household-secret-not-for-production"


@pytest.fixture(autouse=True)
def _auth_and_users():
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    get_settings.cache_clear()

    with session_scope() as session:
        session.add(User(id=USER_A_ID, email="a@test.com", display_name="A", created_at=utcnow()))
        session.add(User(id=USER_B_ID, email="b@test.com", display_name="B", created_at=utcnow()))
        session.add(User(id=USER_C_ID, email="c@test.com", display_name="C", created_at=utcnow()))
        session.flush()
        create_solo_household(session, USER_A_ID)
        create_solo_household(session, USER_B_ID)
        create_solo_household(session, USER_C_ID)

    yield

    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


def _headers(user_id: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {issue_session_jwt(user_id, get_settings())}"}


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def _join_a_household_with_b(client: TestClient) -> None:
    """A invites B; B joins A's household. After this, A is owner,
    B is member, B's solo is merged away."""
    invite = client.post("/api/household/invitations", headers=_headers(USER_A_ID)).json()
    resp = client.post(
        "/api/household/join", json={"code": invite["code"]}, headers=_headers(USER_B_ID)
    )
    assert resp.status_code == 200, resp.text


def _household_state(client: TestClient, user_id: str) -> dict:
    resp = client.get("/api/household", headers=_headers(user_id))
    assert resp.status_code == 200, resp.text
    return resp.json()


# ─────────────────────────────────────────────────────────────────
# Transfer ownership
# ─────────────────────────────────────────────────────────────────


class TestTransferOwner:
    def test_owner_transfers_to_member_roles_swap(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_B_ID},
            headers=_headers(USER_A_ID),
        )
        assert resp.status_code == 200, resp.text
        roles = {m["user_id"]: m["role"] for m in resp.json()["members"]}
        assert roles[USER_A_ID] == "member"
        assert roles[USER_B_ID] == "owner"

    def test_new_owner_can_mint_invitations(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_B_ID},
            headers=_headers(USER_A_ID),
        )
        resp = client.post("/api/household/invitations", headers=_headers(USER_B_ID))
        assert resp.status_code == 200, resp.text

    def test_former_owner_cannot_mint_after_transfer(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_B_ID},
            headers=_headers(USER_A_ID),
        )
        resp = client.post("/api/household/invitations", headers=_headers(USER_A_ID))
        assert resp.status_code == 403

    def test_non_owner_cannot_transfer(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_A_ID},
            headers=_headers(USER_B_ID),
        )
        assert resp.status_code == 403

    def test_transfer_to_non_member_rejected(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        # USER_C is in their own solo, not A's household.
        resp = client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_C_ID},
            headers=_headers(USER_A_ID),
        )
        assert resp.status_code == 404

    def test_transfer_to_self_rejected(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_A_ID},
            headers=_headers(USER_A_ID),
        )
        assert resp.status_code == 400


# ─────────────────────────────────────────────────────────────────
# Member self-removal (leave)
# ─────────────────────────────────────────────────────────────────


class TestLeaveHousehold:
    def test_member_can_leave(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.delete(f"/api/household/members/{USER_B_ID}", headers=_headers(USER_B_ID))
        assert resp.status_code == 204
        # A's view: only A remains.
        members = {m["user_id"] for m in _household_state(client, USER_A_ID)["members"]}
        assert members == {USER_A_ID}

    def test_leaver_gets_fresh_solo(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        a_household_before = _household_state(client, USER_A_ID)["household_id"]
        client.delete(f"/api/household/members/{USER_B_ID}", headers=_headers(USER_B_ID))
        b_household = _household_state(client, USER_B_ID)["household_id"]
        # B is in a different household than A now.
        assert b_household != a_household_before
        # B is owner of their new solo.
        b_role = next(
            m["role"] for m in _household_state(client, USER_B_ID)["members"]
            if m["user_id"] == USER_B_ID
        )
        assert b_role == "owner"

    def test_owner_cannot_leave_without_transferring(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.delete(f"/api/household/members/{USER_A_ID}", headers=_headers(USER_A_ID))
        assert resp.status_code == 409
        assert "Transfer ownership" in resp.json()["detail"]

    def test_solo_owner_cannot_leave_their_own_solo(self, client: TestClient) -> None:
        # USER_A is solo owner; trying to leave should hit the owner-can't-
        # leave path with no other member to transfer to.
        resp = client.delete(f"/api/household/members/{USER_A_ID}", headers=_headers(USER_A_ID))
        assert resp.status_code == 409


# ─────────────────────────────────────────────────────────────────
# Owner-initiated kick
# ─────────────────────────────────────────────────────────────────


class TestKickMember:
    def test_owner_can_kick_member(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        resp = client.delete(f"/api/household/members/{USER_B_ID}", headers=_headers(USER_A_ID))
        assert resp.status_code == 204
        members = {m["user_id"] for m in _household_state(client, USER_A_ID)["members"]}
        assert members == {USER_A_ID}

    def test_kicked_user_gets_fresh_solo_and_can_rejoin(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        client.delete(f"/api/household/members/{USER_B_ID}", headers=_headers(USER_A_ID))

        # B can now accept a new invitation and rejoin.
        invite = client.post("/api/household/invitations", headers=_headers(USER_A_ID)).json()
        resp = client.post(
            "/api/household/join", json={"code": invite["code"]}, headers=_headers(USER_B_ID)
        )
        assert resp.status_code == 200, resp.text

    def test_non_owner_cannot_kick_another_member(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        # Bring in USER_C as second member.
        invite = client.post("/api/household/invitations", headers=_headers(USER_A_ID)).json()
        client.post(
            "/api/household/join", json={"code": invite["code"]}, headers=_headers(USER_C_ID)
        )
        # B (member) tries to kick C (member) → 403.
        resp = client.delete(f"/api/household/members/{USER_C_ID}", headers=_headers(USER_B_ID))
        assert resp.status_code == 403

    def test_kicking_non_member_returns_404(self, client: TestClient) -> None:
        # A is solo owner; C is in their own solo and not a member of A's.
        resp = client.delete(f"/api/household/members/{USER_C_ID}", headers=_headers(USER_A_ID))
        assert resp.status_code == 404

    def test_owner_cannot_be_removed_by_member(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        # B (member) tries to remove A (owner) → 409 (owner can't leave/be
        # removed without transfer first).
        resp = client.delete(f"/api/household/members/{USER_A_ID}", headers=_headers(USER_B_ID))
        assert resp.status_code == 409


# ─────────────────────────────────────────────────────────────────
# Underlying state checks
# ─────────────────────────────────────────────────────────────────


class TestPostOpInvariants:
    def test_only_one_owner_per_household_after_transfer(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        client.post(
            "/api/household/transfer-owner",
            json={"new_owner_user_id": USER_B_ID},
            headers=_headers(USER_A_ID),
        )
        with session_scope() as session:
            household_id = get_household_id(session, USER_A_ID)
            owners = (
                session.query(HouseholdMember)
                .filter_by(household_id=household_id, role="owner")
                .all()
            )
            assert len(owners) == 1
            assert owners[0].user_id == USER_B_ID

    def test_member_count_drops_by_one_after_leave(self, client: TestClient) -> None:
        _join_a_household_with_b(client)
        before = len(_household_state(client, USER_A_ID)["members"])
        client.delete(f"/api/household/members/{USER_B_ID}", headers=_headers(USER_B_ID))
        after = len(_household_state(client, USER_A_ID)["members"])
        assert before - after == 1
