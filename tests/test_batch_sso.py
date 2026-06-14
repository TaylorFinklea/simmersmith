"""SSO lane — web Sign-In-for-Web bug-bash fixes (2026-06-13).

#36 find_or_create_{apple,google}_user had no IntegrityError recovery, so a
    concurrent first web-SSO sign-in 500'd instead of adopting the winner row.
T7 follow-up: the /oauth/sso callback + start error bodies leaked the raw
    SsoError string (JWT decode internals / provider failure detail).
"""
from __future__ import annotations

from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models.user import User
from app.services.sso import (
    find_or_create_apple_user,
    find_or_create_google_user,
)


# ── #36 — concurrent first sign-in converges on one User (no 500) ─────


def _race_winner_on_flush(session, *, winner: User):
    """Wrap session.flush so the first call commits a conflicting `winner`
    row through a separate connection *just before* the loser's INSERT lands —
    deterministically reproducing the concurrent-first-sign-in UNIQUE race that
    a plain sequential test (SQLite single-writer) can't.
    """
    original_flush = session.flush
    state = {"raced": False}

    def flush(*args, **kwargs):
        if not state["raced"]:
            state["raced"] = True
            with session_scope() as other:
                other.add(winner)
                other.commit()
        return original_flush(*args, **kwargs)

    return flush


def test_find_or_create_apple_user_recovers_from_integrity_race(monkeypatch) -> None:
    """The loser of the apple_sub unique race adopts the winner's row."""
    claims = {"sub": "apple-race-sub", "email": "loser@example.com"}

    with session_scope() as session:
        winner = User(apple_sub="apple-race-sub", email="winner@example.com")
        monkeypatch.setattr(session, "flush", _race_winner_on_flush(session, winner=winner))
        # The in-function SELECT misses (winner not yet committed), the INSERT
        # is attempted, the patched flush commits the winner first, then the
        # real flush raises IntegrityError -> recovery re-SELECTs the winner.
        user = find_or_create_apple_user(session, claims)
        winner_id = winner.id
        assert user.id == winner_id
        session.commit()

    with session_scope() as session:
        rows = session.scalars(
            select(User).where(User.apple_sub == "apple-race-sub")
        ).all()
        assert len(rows) == 1
        assert rows[0].email == "winner@example.com"


def test_find_or_create_google_user_recovers_from_integrity_race(monkeypatch) -> None:
    """The loser of the google_sub unique race adopts the winner's row."""
    claims = {"sub": "google-race-sub", "email": "loser@example.com", "name": "Race"}

    with session_scope() as session:
        winner = User(google_sub="google-race-sub", email="winner@example.com")
        monkeypatch.setattr(session, "flush", _race_winner_on_flush(session, winner=winner))
        user = find_or_create_google_user(session, claims)
        winner_id = winner.id
        assert user.id == winner_id
        session.commit()

    with session_scope() as session:
        rows = session.scalars(
            select(User).where(User.google_sub == "google-race-sub")
        ).all()
        assert len(rows) == 1
        assert rows[0].email == "winner@example.com"


def test_find_or_create_apple_user_creates_when_absent() -> None:
    """No race: a brand-new apple_sub still mints exactly one User."""
    claims = {"sub": "apple-fresh-sub", "email": "fresh@example.com"}
    with session_scope() as session:
        user = find_or_create_apple_user(session, claims)
        assert user.apple_sub == "apple-fresh-sub"
        session.commit()
        new_id = user.id

    # Same sub again returns the existing row rather than a duplicate.
    with session_scope() as session:
        again = find_or_create_apple_user(session, {"sub": "apple-fresh-sub"})
        assert again.id == new_id


# ── SSO callbacks reject a malformed state with 400 ─────────────────


def test_google_callback_rejects_bad_state(client, monkeypatch) -> None:
    """A malformed state is rejected with 400 invalid-state."""
    monkeypatch.setenv("SIMMERSMITH_JWT_SECRET", "test-jwt-secret")
    get_settings.cache_clear()

    r = client.get(
        "/oauth/sso/google/callback",
        params={"code": "irrelevant", "state": "not-a-real-jwt"},
        follow_redirects=False,
    )
    assert r.status_code == 400
    assert "invalid state" in r.json()["detail"].lower()


def test_apple_callback_rejects_bad_state(client, monkeypatch) -> None:
    monkeypatch.setenv("SIMMERSMITH_JWT_SECRET", "test-jwt-secret")
    get_settings.cache_clear()

    r = client.post(
        "/oauth/sso/apple/callback",
        data={"code": "irrelevant", "state": "garbage-state"},
        follow_redirects=False,
    )
    assert r.status_code == 400
    assert "invalid state" in r.json()["detail"].lower()
