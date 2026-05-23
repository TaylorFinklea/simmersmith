"""Regression tests for MCP-layer user resolution.

Background: M21 (household sharing) made ``household_id`` a required
field on ``CurrentUser``. The REST FastAPI dependency was updated to
resolve it, but the MCP-layer user-construction in
``app/mcp/{weeks,profile,ingredients,recipes}.py`` was not — every
authed MCP tool call shipped from build 100 onward failed with
``TypeError: CurrentUser.__init__() missing 1 required positional
argument: 'household_id'``. The fix centralizes resolution in
``app/mcp/_helpers._current_user(session)``; this test locks in the
contract so a future signature change can't silently break it again.
"""
from __future__ import annotations


def test_current_user_resolves_both_id_and_household() -> None:
    from app.db import session_scope
    from app.mcp._helpers import _current_user

    with session_scope() as session:
        user = _current_user(session)

    assert user.id, "id must be set"
    assert user.household_id, "household_id must be set (M21 requirement)"


def test_current_user_creates_solo_household_for_new_user() -> None:
    """A user_id with no membership lazy-gets a solo household, matching
    the REST ``get_current_user`` behavior — never returns a partial
    ``CurrentUser`` that would break downstream household-scoped queries."""
    from app.db import session_scope
    from app.mcp._helpers import _current_user, _current_user_id_var
    from app.models._base import new_id
    from app.services.households import get_household_id_or_none

    fresh_user_id = new_id()
    token = _current_user_id_var.set(fresh_user_id)
    try:
        with session_scope() as session:
            user = _current_user(session)
            assert user.id == fresh_user_id
            assert user.household_id
            # The household was actually persisted.
            assert get_household_id_or_none(session, fresh_user_id) == user.household_id
    finally:
        _current_user_id_var.reset(token)
