from __future__ import annotations

from typing import Any

from . import mcp
from ._helpers import _call_route, _current_user_id

from app.api.preferences import get_preferences, post_preferences, post_score_meal
from app.api.profile import get_profile, put_profile
from app.auth import CurrentUser
from app.db import session_scope
from app.schemas import (
    MealScoreRequest,
    PreferenceBatchUpsertRequest,
    ProfileUpdateRequest,
)


def _mcp_user() -> CurrentUser:
    return CurrentUser(id=_current_user_id())


@mcp.tool(description="Get the household profile, staples, and profile settings.")
def profile_get() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: get_profile(session=session, current_user=_mcp_user()))


@mcp.tool(description="Update the household profile settings and staples.")
def profile_update(
    settings: dict[str, str], staples: list[dict[str, Any]] | None = None
) -> dict[str, Any]:
    with session_scope() as session:
        payload = ProfileUpdateRequest(settings=settings, staples=staples)
        return _call_route(lambda: put_profile(payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get meal preference signals and the summarized preference context.")
def preferences_get() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: get_preferences(session=session, current_user=_mcp_user()))


@mcp.tool(description="Upsert preference signals in batch.")
def preferences_upsert(signals: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = PreferenceBatchUpsertRequest(signals=signals)
        return _call_route(lambda: post_preferences(payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Score a meal candidate against saved preferences.")
def preferences_score_meal(
    recipe_name: str,
    cuisine: str = "",
    meal_type: str = "",
    ingredient_names: list[str] | None = None,
    tags: list[str] | None = None,
) -> dict[str, Any]:
    with session_scope() as session:
        payload = MealScoreRequest(
            recipe_name=recipe_name,
            cuisine=cuisine,
            meal_type=meal_type,
            ingredient_names=ingredient_names or [],
            tags=tags or [],
        )
        return _call_route(lambda: post_score_meal(payload, session=session, current_user=_mcp_user()))
