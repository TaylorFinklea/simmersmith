from __future__ import annotations

from typing import Any

from . import mcp
from ._helpers import _call_route, _current_user_id

from app.api.weeks import (
    apply_draft,
    approve_week,
    create_week,
    create_week_export,
    current_week,
    import_week_pricing,
    pricing_detail,
    ready_for_ai,
    regenerate_grocery,
    save_week_feedback,
    update_meals,
    week_by_start,
    week_changes,
    week_detail,
    week_exports,
    week_feedback,
    week_list,
)
from app.api.exports import complete_export, export_apple_reminders_payload, export_detail
from app.auth import CurrentUser
from app.db import session_scope
from app.schemas import (
    DraftFromAIRequest,
    ExportCompleteRequest,
    ExportCreateRequest,
    FeedbackEntryPayload,
    MealUpdatePayload,
    PricingImportRequest,
    WeekCreateRequest,
)


def _mcp_user() -> CurrentUser:
    return CurrentUser(id=_current_user_id())


@mcp.tool(description="List recent weeks.")
def weeks_list(limit: int = 6) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_list(limit=limit, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get the current week.")
def weeks_get_current() -> dict[str, Any] | None:
    with session_scope() as session:
        return _call_route(lambda: current_week(session=session, current_user=_mcp_user()))


@mcp.tool(description="Get a week by week start date (YYYY-MM-DD).")
def weeks_get_by_start(week_start: str) -> dict[str, Any] | None:
    with session_scope() as session:
        return _call_route(lambda: week_by_start(week_start=week_start, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get a week by ID.")
def weeks_get(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: week_detail(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Create a week if it does not exist for the given start date.")
def weeks_create(week_start: str, notes: str = "") -> dict[str, Any]:
    with session_scope() as session:
        payload = WeekCreateRequest(week_start=week_start, notes=notes)
        return _call_route(lambda: create_week(payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Apply an AI draft payload to a week.")
def weeks_apply_ai_draft(
    week_id: str,
    prompt: str,
    model: str = "skill-chat",
    profile_updates: dict[str, str] | None = None,
    recipes: list[dict[str, Any]] | None = None,
    meal_plan: list[dict[str, Any]] | None = None,
    week_notes: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = DraftFromAIRequest(
            prompt=prompt,
            model=model,
            profile_updates=profile_updates or {},
            recipes=recipes or [],
            meal_plan=meal_plan or [],
            week_notes=week_notes,
        )
        return _call_route(lambda: apply_draft(week_id, payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Replace the meals for a week.")
def weeks_update_meals(week_id: str, meals: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = [MealUpdatePayload.model_validate(item) for item in meals]
        return _call_route(lambda: update_meals(week_id, payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get change history for a week.")
def weeks_get_changes(week_id: str) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_changes(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Mark a week ready for AI review.")
def weeks_mark_ready_for_ai(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: ready_for_ai(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Approve a week.")
def weeks_approve(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: approve_week(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Regenerate the grocery list for a week.")
def weeks_regenerate_grocery(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: regenerate_grocery(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get saved feedback for a week.")
def weeks_get_feedback(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: week_feedback(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Save feedback entries for a week.")
def weeks_save_feedback(week_id: str, entries: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = [FeedbackEntryPayload.model_validate(item) for item in entries]
        return _call_route(lambda: save_week_feedback(week_id, payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get pricing results for a week.")
def weeks_get_pricing(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: pricing_detail(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Import pricing candidates for a week.")
def weeks_import_pricing(
    week_id: str, retailers: list[str], items: list[dict[str, Any]]
) -> dict[str, Any]:
    with session_scope() as session:
        payload = PricingImportRequest(retailers=retailers, items=items)
        return _call_route(lambda: import_week_pricing(week_id, payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="List export runs for a week.")
def weeks_list_exports(week_id: str) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_exports(week_id, session=session, current_user=_mcp_user()))


@mcp.tool(description="Create an export run for a week.")
def weeks_create_export(week_id: str, destination: str, export_type: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = ExportCreateRequest(destination=destination, export_type=export_type)
        return _call_route(lambda: create_week_export(week_id, payload, session=session, current_user=_mcp_user()))


@mcp.tool(description="Get a single export run by ID.")
def exports_get(export_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: export_detail(export_id, session=session))


@mcp.tool(description="Get the Apple Reminders payload for an export run.")
def exports_get_apple_reminders(export_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: export_apple_reminders_payload(export_id, session=session))


@mcp.tool(description="Mark an export run completed or failed.")
def exports_complete(
    export_id: str,
    status: str,
    error: str = "",
    external_ref: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = ExportCompleteRequest(status=status, error=error, external_ref=external_ref)
        return _call_route(lambda: complete_export(export_id, payload, session=session))
