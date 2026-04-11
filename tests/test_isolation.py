"""Cross-user isolation tests.

Proves that user A cannot see, modify, or reference user B's data.
Uses real session JWTs so the full auth stack is exercised.
"""
from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from app.auth import issue_session_jwt
from app.config import get_settings
from app.db import session_scope
from app.main import app
from app.models.user import User
from app.models._base import utcnow

USER_A_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
USER_B_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
TEST_JWT_SECRET = "test-isolation-secret-not-for-production"


@pytest.fixture(autouse=True)
def setup_auth_and_users():
    """Enable JWT auth and create two test users."""
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    get_settings.cache_clear()

    with session_scope() as session:
        session.add(User(id=USER_A_ID, email="a@test.com", display_name="User A", created_at=utcnow()))
        session.add(User(id=USER_B_ID, email="b@test.com", display_name="User B", created_at=utcnow()))

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


# ── Weeks ───────────────────────────────────────────────────────────


class TestWeekIsolation:
    def test_user_b_cannot_see_user_a_weeks(self, client, headers_a, headers_b):
        resp = client.post("/api/weeks", json={"week_start": "2026-04-13"}, headers=headers_a)
        assert resp.status_code == 200
        week_id = resp.json()["week_id"]

        resp = client.get("/api/weeks", headers=headers_b)
        assert resp.status_code == 200
        assert resp.json() == []

        resp = client.get(f"/api/weeks/{week_id}", headers=headers_b)
        assert resp.status_code == 404

    def test_user_b_cannot_get_user_a_week_by_start(self, client, headers_a, headers_b):
        client.post("/api/weeks", json={"week_start": "2026-04-13"}, headers=headers_a)

        resp = client.get("/api/weeks/by-start", params={"week_start": "2026-04-13"}, headers=headers_b)
        assert resp.status_code == 200
        assert resp.json() is None

    def test_same_week_start_different_users(self, client, headers_a, headers_b):
        resp_a = client.post("/api/weeks", json={"week_start": "2026-04-13"}, headers=headers_a)
        assert resp_a.status_code == 200

        resp_b = client.post("/api/weeks", json={"week_start": "2026-04-13"}, headers=headers_b)
        assert resp_b.status_code == 200

        assert resp_a.json()["week_id"] != resp_b.json()["week_id"]


# ── Recipes ─────────────────────────────────────────────────────────


class TestRecipeIsolation:
    def test_user_b_cannot_see_user_a_recipes(self, client, headers_a, headers_b):
        resp = client.post("/api/recipes", json={
            "name": "Secret Recipe", "ingredients": [], "steps": [],
        }, headers=headers_a)
        assert resp.status_code == 200
        recipe_id = resp.json()["recipe_id"]

        resp = client.get("/api/recipes", headers=headers_b)
        assert resp.status_code == 200
        recipe_ids = [r["recipe_id"] for r in resp.json()]
        assert recipe_id not in recipe_ids

        resp = client.get(f"/api/recipes/{recipe_id}", headers=headers_b)
        assert resp.status_code == 404


# ── Assistant ───────────────────────────────────────────────────────


class TestAssistantIsolation:
    def test_user_b_cannot_see_user_a_threads(self, client, headers_a, headers_b):
        resp = client.post("/api/assistant/threads", json={"title": "My Chat"}, headers=headers_a)
        assert resp.status_code == 200
        thread_id = resp.json()["thread_id"]

        resp = client.get("/api/assistant/threads", headers=headers_b)
        assert resp.status_code == 200
        assert resp.json() == []

        resp = client.get(f"/api/assistant/threads/{thread_id}", headers=headers_b)
        assert resp.status_code == 404


# ── Profile ─────────────────────────────────────────────────────────


class TestProfileIsolation:
    def test_user_a_profile_changes_invisible_to_b(self, client, headers_a, headers_b):
        client.put("/api/profile", json={
            "settings": {"household_name": "A's Kitchen"},
            "staples": [{"staple_name": "Butter", "notes": ""}],
        }, headers=headers_a)

        resp = client.get("/api/profile", headers=headers_b)
        assert resp.status_code == 200
        data = resp.json()
        # B either has no household_name or it's empty (not A's value)
        assert data["settings"].get("household_name", "") != "A's Kitchen"
        staple_names = [s["staple_name"] for s in data["staples"]]
        assert "Butter" not in staple_names


# ── Preferences ─────────────────────────────────────────────────────


class TestPreferenceIsolation:
    def test_user_b_cannot_see_user_a_preferences(self, client, headers_a, headers_b):
        client.put("/api/preferences", json={
            "signals": [
                {"signal_type": "cuisine", "name": "Thai", "score": 5, "weight": 3},
            ],
        }, headers=headers_a)

        resp = client.get("/api/preferences", headers=headers_b)
        assert resp.status_code == 200
        assert resp.json()["signals"] == []
