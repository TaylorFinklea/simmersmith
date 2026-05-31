"""Concurrent first sign-in safety (M15).

Two halves:

PART A — the 500. ``auth_apple`` / ``auth_google`` SELECT-then-INSERT with
no IntegrityError handling. Two concurrent first sign-ins for the same
identity → the second commit violates ``users.apple_sub``/``google_sub``
unique → HTTP 500. The routes now recover by adopting the row the race
winner created. TestClient is single-threaded, so we force the race window
with a session proxy whose *first* lookup misses while the conflicting row
already exists, driving the route into its IntegrityError-recovery branch.

PART B — duplicate solo household. The "one household per user" invariant
was app-logic only; a concurrent lazy ``create_solo_household`` could insert
two memberships for one user. ``uq_household_members_user`` now enforces it
at the schema level.
"""
from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.api import auth as auth_module
from app.config import get_settings
from app.db import get_session, session_scope
from app.main import app
from app.models import Household, HouseholdMember, User
from app.models._base import new_id, utcnow
from app.services.households import create_solo_household, get_household_id_or_none


TEST_JWT_SECRET = "test-auth-concurrency-secret-not-for-production"


@pytest.fixture(autouse=True)
def configured_auth():
    # issue_session_jwt (called at the end of each route) needs a secret.
    os.environ["SIMMERSMITH_JWT_SECRET"] = TEST_JWT_SECRET
    get_settings.cache_clear()
    yield
    os.environ.pop("SIMMERSMITH_JWT_SECRET", None)
    get_settings.cache_clear()


@pytest.fixture
def client() -> TestClient:
    with TestClient(app) as c:
        yield c


# ── A session proxy that forces the first User lookup to miss ────────


class _NoneResult:
    """Stand-in scalars() result whose one_or_none() reports 'no row',
    simulating the race window where the conflicting row isn't visible
    to this request's first SELECT yet."""

    def one_or_none(self):
        return None


class _MissFirstSession:
    """Delegates to a real Session but makes the first scalars() call
    report no row, so the route takes its create branch and then hits the
    real DB unique constraint on flush — exercising the recovery path."""

    def __init__(self, real):
        self._real = real
        self._missed = False

    def scalars(self, *args, **kwargs):
        if not self._missed:
            self._missed = True
            return _NoneResult()
        return self._real.scalars(*args, **kwargs)

    def __getattr__(self, name):
        return getattr(self._real, name)


def _override_miss_first_session():
    with session_scope() as real:
        yield _MissFirstSession(real)


# ── PART A: the 500 recovers to the existing user ───────────────────


def test_apple_concurrent_first_signin_recovers(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr(
        auth_module,
        "verify_apple_identity_token",
        lambda token, settings: {"sub": "apple-race-1", "email": "race@example.com"},
    )
    # The race winner already created this row.
    with session_scope() as session:
        winner = User(id=new_id(), apple_sub="apple-race-1", email="race@example.com", created_at=utcnow())
        session.add(winner)
        session.commit()
        winner_id = winner.id

    app.dependency_overrides[get_session] = _override_miss_first_session
    try:
        resp = client.post("/api/auth/apple", json={"identity_token": "x"})
    finally:
        app.dependency_overrides.pop(get_session, None)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["user_id"] == winner_id
    assert body["is_new_user"] is False
    with session_scope() as session:
        rows = session.scalars(select(User).where(User.apple_sub == "apple-race-1")).all()
        assert len(rows) == 1


def test_google_concurrent_first_signin_recovers(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr(
        auth_module,
        "verify_google_identity_token",
        lambda token, settings: {"sub": "google-race-1", "email": "g@example.com", "name": "G"},
    )
    with session_scope() as session:
        winner = User(id=new_id(), google_sub="google-race-1", email="g@example.com", display_name="G", created_at=utcnow())
        session.add(winner)
        session.commit()
        winner_id = winner.id

    app.dependency_overrides[get_session] = _override_miss_first_session
    try:
        resp = client.post("/api/auth/google", json={"identity_token": "x"})
    finally:
        app.dependency_overrides.pop(get_session, None)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["user_id"] == winner_id
    assert body["is_new_user"] is False
    with session_scope() as session:
        rows = session.scalars(select(User).where(User.google_sub == "google-race-1")).all()
        assert len(rows) == 1


def test_apple_clean_first_signin_still_creates(client: TestClient, monkeypatch) -> None:
    """Regression: an uncontended first sign-in still creates the user."""
    monkeypatch.setattr(
        auth_module,
        "verify_apple_identity_token",
        lambda token, settings: {"sub": "apple-fresh-1", "email": "fresh@example.com"},
    )
    resp = client.post("/api/auth/apple", json={"identity_token": "x"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["is_new_user"] is True
    with session_scope() as session:
        rows = session.scalars(select(User).where(User.apple_sub == "apple-fresh-1")).all()
        assert len(rows) == 1


# ── PART B: one-household-per-user is a schema guarantee ─────────────


def test_duplicate_membership_for_user_is_rejected() -> None:
    uid = new_id()
    with session_scope() as session:
        create_solo_household(session, uid)
        session.commit()
    # A second membership under a different household for the same user
    # must violate uq_household_members_user (M15).
    with session_scope() as session:
        other = Household(id=new_id(), name="", created_by_user_id=uid, created_at=utcnow(), updated_at=utcnow())
        session.add(other)
        session.flush()
        session.add(
            HouseholdMember(id=new_id(), household_id=other.id, user_id=uid, role="owner", joined_at=utcnow())
        )
        with pytest.raises(IntegrityError):
            session.flush()
        # Clear the failed transaction so session_scope's exit commit is clean.
        session.rollback()


def test_create_solo_household_is_idempotent() -> None:
    uid = new_id()
    with session_scope() as session:
        first = create_solo_household(session, uid)
        session.commit()
    with session_scope() as session:
        second = create_solo_household(session, uid)
        assert second == first
        assert get_household_id_or_none(session, uid) == first
        rows = session.scalars(
            select(HouseholdMember).where(HouseholdMember.user_id == uid)
        ).all()
        assert len(rows) == 1
