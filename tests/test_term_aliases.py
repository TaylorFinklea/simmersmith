"""M26 Phase 3 — per-household shorthand dictionary.

Aliases are case-normalized, household-scoped, and injected into both
the planner's `PlanningContext.term_aliases` and the assistant's
system-prompt context string.
"""
from __future__ import annotations

from app.config import get_settings
from app.db import session_scope
from app.services.aliases import (
    aliases_map,
    delete_alias,
    list_aliases,
    upsert_alias,
)
from app.services.week_planner import gather_planning_context

_uid = get_settings().local_user_id


def test_alias_upsert_and_list_household_scoped() -> None:
    """Two households with the same `term` keep separate expansions;
    each household sees only its own aliases."""
    with session_scope() as session:
        upsert_alias(session, household_id="house-a", term="chx", expansion="chicken")
        upsert_alias(session, household_id="house-a", term="bf", expansion="beef")
        upsert_alias(session, household_id="house-b", term="chx", expansion="chickpeas")

        a_aliases = list_aliases(session, household_id="house-a")
        b_aliases = list_aliases(session, household_id="house-b")

    a_terms = {a.term: a.expansion for a in a_aliases}
    b_terms = {a.term: a.expansion for a in b_aliases}
    assert a_terms == {"chx": "chicken", "bf": "beef"}
    assert b_terms == {"chx": "chickpeas"}


def test_alias_upsert_overwrites_expansion() -> None:
    with session_scope() as session:
        upsert_alias(session, household_id="house-c", term="tj", expansion="Trader Joe's")
        upsert_alias(session, household_id="house-c", term="tj", expansion="Tasty Joe's")
        result = aliases_map(session, household_id="house-c")
    assert result == {"tj": "Tasty Joe's"}


def test_alias_term_is_case_normalized() -> None:
    """`CHX`, `Chx`, `chx` collide on the same row."""
    with session_scope() as session:
        upsert_alias(session, household_id="house-d", term="CHX", expansion="chicken")
        upsert_alias(session, household_id="house-d", term="Chx", expansion="chicken thighs")
        result = aliases_map(session, household_id="house-d")
    assert result == {"chx": "chicken thighs"}


def test_alias_delete_round_trip() -> None:
    with session_scope() as session:
        upsert_alias(session, household_id="house-e", term="chx", expansion="chicken")
        deleted = delete_alias(session, household_id="house-e", term="chx")
        absent = delete_alias(session, household_id="house-e", term="chx")
        result = aliases_map(session, household_id="house-e")
    assert deleted is True
    assert absent is False
    assert result == {}


def test_alias_validation() -> None:
    with session_scope() as session:
        try:
            upsert_alias(session, household_id="house-f", term="", expansion="chicken")
            raise AssertionError("expected ValueError for empty term")
        except ValueError:
            pass
        try:
            upsert_alias(session, household_id="house-f", term="chx", expansion="")
            raise AssertionError("expected ValueError for empty expansion")
        except ValueError:
            pass


def test_planning_context_includes_aliases() -> None:
    """`gather_planning_context` surfaces the household's alias map for
    the system-prompt assembler."""
    with session_scope() as session:
        upsert_alias(session, household_id=_uid, term="chx", expansion="chicken")
        upsert_alias(session, household_id=_uid, term="bf", expansion="beef")
        ctx = gather_planning_context(session, _uid, household_id=_uid)

    assert ctx.term_aliases == {"chx": "chicken", "bf": "beef"}
