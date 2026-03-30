from __future__ import annotations

import argparse
import json
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import HTTPException
from fastapi.encoders import jsonable_encoder
from mcp.server.fastmcp import FastMCP
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings

from app.api.exports import complete_export, export_apple_reminders_payload, export_detail
from app.api.preferences import get_preferences, post_preferences, post_score_meal
from app.api.profile import get_profile, put_profile
from app.api.recipes import (
    archive_recipe_route,
    create_metadata_item_route,
    estimate_recipe_nutrition_route,
    import_recipe_route,
    import_recipe_text_route,
    nutrition_match_route,
    nutrition_search_route,
    recipe_companion_drafts_route,
    recipe_detail_route,
    recipe_metadata_route,
    recipe_suggestion_draft_route,
    recipe_variation_draft_route,
    restore_recipe_route,
    save_recipe,
)
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
from app.config import Settings, get_settings
from app.db import session_scope
from app.main import healthcheck
from app.models import AIRun, AssistantMessage
from app.schemas import (
    AssistantRespondRequest,
    AssistantThreadCreateRequest,
    DraftFromAIRequest,
    ExportCompleteRequest,
    ExportCreateRequest,
    FeedbackEntryPayload,
    IngredientNutritionMatchRequest,
    ManagedListItemCreateRequest,
    MealScoreRequest,
    MealUpdatePayload,
    PreferenceBatchUpsertRequest,
    PricingImportRequest,
    ProfileUpdateRequest,
    RecipeCompanionDraftRequest,
    RecipeImportRequest,
    RecipePayload,
    RecipeSuggestionDraftRequest,
    RecipeTextImportRequest,
    RecipeVariationDraftRequest,
    WeekCreateRequest,
)
from app.services.ai import profile_settings_map
from app.services.assistant_ai import run_assistant_turn
from app.services.assistant_threads import (
    archive_thread,
    create_message,
    create_thread,
    get_thread,
    list_threads,
    update_assistant_message,
)
from app.services.bootstrap import run_migrations, seed_defaults
from app.services.exports import get_export_run
from app.services.presenters import (
    assistant_message_payload,
    assistant_thread_payload,
    assistant_thread_summary_payload,
    recipe_payload,
    recipes_payload,
)
from app.services.recipes import get_recipe, list_recipes


def _settings() -> Settings:
    return get_settings()


def _json_ready(value: Any) -> Any:
    return jsonable_encoder(value)


def _raise_tool_error(exc: HTTPException) -> None:
    detail = exc.detail if isinstance(exc.detail, str) else json.dumps(exc.detail)
    raise ValueError(detail) from exc


def _call_route(callback):
    try:
        return _json_ready(callback())
    except HTTPException as exc:
        _raise_tool_error(exc)


class StaticBearerTokenVerifier(TokenVerifier):
    def __init__(self, token: str, *, client_id: str = "simmersmith-mcp-client", scopes: list[str] | None = None):
        self._token = token.strip()
        self._client_id = client_id
        self._scopes = scopes or []

    async def verify_token(self, token: str) -> AccessToken | None:
        if not self._token or token.strip() != self._token:
            return None
        return AccessToken(
            token=token.strip(),
            client_id=self._client_id,
            scopes=self._scopes,
            expires_at=int(time.time()) + 86400,
        )


@asynccontextmanager
async def lifespan(_: FastMCP):
    run_migrations()
    with session_scope() as session:
        seed_defaults(session)
    yield


mcp = FastMCP(
    name="SimmerSmith",
    instructions=(
        "Use these tools to read and update the SimmerSmith meal-planning app state. "
        "Prefer draft-first flows for recipe AI actions and assistant interactions."
    ),
    lifespan=lifespan,
)


@mcp.tool(description="Get SimmerSmith health and AI capability status.")
async def health() -> dict[str, Any]:
    return _json_ready(await healthcheck())


@mcp.tool(description="List recipes in SimmerSmith.")
def recipes_list(include_archived: bool = False, cuisine: str = "", tags: list[str] | None = None) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(
            lambda: recipes_payload(
                session,
                include_archived=include_archived,
                cuisine=cuisine,
                tags=tags or [],
            )
        )


@mcp.tool(description="Get one recipe by ID.")
def recipes_get(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: recipe_detail_route(recipe_id, session=session))


@mcp.tool(description="Create or update a recipe.")
def recipes_save(payload: RecipePayload) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: save_recipe(payload, session=session))


@mcp.tool(description="Import a recipe draft from a source URL.")
def recipes_import_from_url(url: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeImportRequest(url=url)
        return _call_route(lambda: import_recipe_route(payload, session=session).model_dump(mode="json"))


@mcp.tool(description="Import a recipe draft from extracted text, OCR, or pasted content.")
def recipes_import_from_text(
    text: str,
    title: str = "",
    source: str = "scan_import",
    source_label: str = "",
    source_url: str = "",
) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeTextImportRequest(
            text=text,
            title=title,
            source=source,
            source_label=source_label,
            source_url=source_url,
        )
        return _call_route(lambda: import_recipe_text_route(payload, session=session).model_dump(mode="json"))


@mcp.tool(description="List recipe metadata including cuisines, tags, units, and templates.")
def recipes_metadata() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: recipe_metadata_route(session=session))


@mcp.tool(description="Add a managed recipe metadata item such as a cuisine, tag, or unit.")
def recipes_add_metadata_item(kind: str, name: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = ManagedListItemCreateRequest(name=name)
        return _call_route(lambda: create_metadata_item_route(kind, payload, session=session))


@mcp.tool(description="Generate a recipe suggestion draft.")
def recipes_suggestion_draft(goal: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeSuggestionDraftRequest(goal=goal)
        return _call_route(lambda: recipe_suggestion_draft_route(payload, session=session, settings=_settings()))


@mcp.tool(description="Generate three companion recipe drafts for a recipe.")
def recipes_companion_drafts(recipe_id: str, focus: str = "sides_and_sauces") -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeCompanionDraftRequest(focus=focus)
        return _call_route(
            lambda: recipe_companion_drafts_route(
                recipe_id,
                payload,
                session=session,
                settings=_settings(),
            )
        )


@mcp.tool(description="Generate a recipe variation draft for an existing recipe.")
def recipes_variation_draft(recipe_id: str, goal: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = RecipeVariationDraftRequest(goal=goal)
        return _call_route(
            lambda: recipe_variation_draft_route(
                recipe_id,
                payload,
                session=session,
                settings=_settings(),
            )
        )


@mcp.tool(description="Estimate nutrition for a recipe payload.")
def recipes_nutrition_estimate(payload: RecipePayload) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: estimate_recipe_nutrition_route(payload, session=session))


@mcp.tool(description="Search the nutrition database by ingredient or food name.")
def recipes_nutrition_search(query: str = "", limit: int = 20) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: nutrition_search_route(q=query, limit=limit, session=session))


@mcp.tool(description="Save or update a nutrition-item match for an ingredient.")
def recipes_nutrition_match(ingredient_name: str, normalized_name: str | None, nutrition_item_id: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = IngredientNutritionMatchRequest(
            ingredient_name=ingredient_name,
            normalized_name=normalized_name,
            nutrition_item_id=nutrition_item_id,
        )
        return _call_route(lambda: nutrition_match_route(payload, session=session))


@mcp.tool(description="Archive a recipe.")
def recipes_archive(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: archive_recipe_route(recipe_id, session=session))


@mcp.tool(description="Restore an archived recipe.")
def recipes_restore(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: restore_recipe_route(recipe_id, session=session))


@mcp.tool(description="Delete a recipe permanently.")
def recipes_delete(recipe_id: str) -> dict[str, Any]:
    with session_scope() as session:
        recipe = get_recipe(session, recipe_id)
        if recipe is None:
            raise ValueError("Recipe not found")
        session.delete(recipe)
        return {"deleted": True, "recipe_id": recipe_id}


@mcp.tool(description="Get the household profile, staples, and profile settings.")
def profile_get() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: get_profile(session=session))


@mcp.tool(description="Update the household profile settings and staples.")
def profile_update(settings: dict[str, str], staples: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    with session_scope() as session:
        payload = ProfileUpdateRequest(settings=settings, staples=staples)
        return _call_route(lambda: put_profile(payload, session=session))


@mcp.tool(description="Get meal preference signals and the summarized preference context.")
def preferences_get() -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: get_preferences(session=session))


@mcp.tool(description="Upsert preference signals in batch.")
def preferences_upsert(signals: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = PreferenceBatchUpsertRequest(signals=signals)
        return _call_route(lambda: post_preferences(payload, session=session))


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
        return _call_route(lambda: post_score_meal(payload, session=session))


@mcp.tool(description="List recent weeks.")
def weeks_list(limit: int = 6) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_list(limit=limit, session=session))


@mcp.tool(description="Get the current week.")
def weeks_get_current() -> dict[str, Any] | None:
    with session_scope() as session:
        return _call_route(lambda: current_week(session=session))


@mcp.tool(description="Get a week by week start date (YYYY-MM-DD).")
def weeks_get_by_start(week_start: str) -> dict[str, Any] | None:
    with session_scope() as session:
        return _call_route(lambda: week_by_start(week_start=week_start, session=session))


@mcp.tool(description="Get a week by ID.")
def weeks_get(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: week_detail(week_id, session=session))


@mcp.tool(description="Create a week if it does not exist for the given start date.")
def weeks_create(week_start: str, notes: str = "") -> dict[str, Any]:
    with session_scope() as session:
        payload = WeekCreateRequest(week_start=week_start, notes=notes)
        return _call_route(lambda: create_week(payload, session=session))


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
        return _call_route(lambda: apply_draft(week_id, payload, session=session))


@mcp.tool(description="Replace the meals for a week.")
def weeks_update_meals(week_id: str, meals: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = [MealUpdatePayload.model_validate(item) for item in meals]
        return _call_route(lambda: update_meals(week_id, payload, session=session))


@mcp.tool(description="Get change history for a week.")
def weeks_get_changes(week_id: str) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_changes(week_id, session=session))


@mcp.tool(description="Mark a week ready for AI review.")
def weeks_mark_ready_for_ai(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: ready_for_ai(week_id, session=session))


@mcp.tool(description="Approve a week.")
def weeks_approve(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: approve_week(week_id, session=session))


@mcp.tool(description="Regenerate the grocery list for a week.")
def weeks_regenerate_grocery(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: regenerate_grocery(week_id, session=session))


@mcp.tool(description="Get saved feedback for a week.")
def weeks_get_feedback(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: week_feedback(week_id, session=session))


@mcp.tool(description="Save feedback entries for a week.")
def weeks_save_feedback(week_id: str, entries: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = [FeedbackEntryPayload.model_validate(item) for item in entries]
        return _call_route(lambda: save_week_feedback(week_id, payload, session=session))


@mcp.tool(description="Get pricing results for a week.")
def weeks_get_pricing(week_id: str) -> dict[str, Any]:
    with session_scope() as session:
        return _call_route(lambda: pricing_detail(week_id, session=session))


@mcp.tool(description="Import pricing candidates for a week.")
def weeks_import_pricing(week_id: str, retailers: list[str], items: list[dict[str, Any]]) -> dict[str, Any]:
    with session_scope() as session:
        payload = PricingImportRequest(retailers=retailers, items=items)
        return _call_route(lambda: import_week_pricing(week_id, payload, session=session))


@mcp.tool(description="List export runs for a week.")
def weeks_list_exports(week_id: str) -> list[dict[str, Any]]:
    with session_scope() as session:
        return _call_route(lambda: week_exports(week_id, session=session))


@mcp.tool(description="Create an export run for a week.")
def weeks_create_export(week_id: str, destination: str, export_type: str) -> dict[str, Any]:
    with session_scope() as session:
        payload = ExportCreateRequest(destination=destination, export_type=export_type)
        return _call_route(lambda: create_week_export(week_id, payload, session=session))


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


@mcp.tool(description="List assistant threads.")
def assistant_list_threads() -> list[dict[str, Any]]:
    with session_scope() as session:
        return _json_ready([assistant_thread_summary_payload(thread) for thread in list_threads(session)])


@mcp.tool(description="Create a new assistant thread.")
def assistant_create_thread(title: str = "") -> dict[str, Any]:
    with session_scope() as session:
        payload = AssistantThreadCreateRequest(title=title)
        thread = create_thread(session, title=payload.title)
        return _json_ready(assistant_thread_summary_payload(thread))


@mcp.tool(description="Get a single assistant thread with all messages.")
def assistant_get_thread(thread_id: str) -> dict[str, Any]:
    with session_scope() as session:
        thread = get_thread(session, thread_id)
        if thread is None:
            raise ValueError("Assistant thread not found")
        return _json_ready(assistant_thread_payload(thread))


@mcp.tool(description="Archive an assistant thread.")
def assistant_archive_thread(thread_id: str) -> dict[str, Any]:
    with session_scope() as session:
        thread = get_thread(session, thread_id)
        if thread is None:
            raise ValueError("Assistant thread not found")
        archive_thread(session, thread)
        return {"archived": True, "thread_id": thread_id}


@mcp.tool(description="Run one assistant turn and persist the result to the thread.")
def assistant_respond(
    thread_id: str,
    text: str,
    intent: str = "general",
    attached_recipe_id: str | None = None,
    attached_recipe_draft: dict[str, Any] | None = None,
) -> dict[str, Any]:
    settings = _settings()
    request = AssistantRespondRequest(
        text=text,
        attached_recipe_id=attached_recipe_id,
        attached_recipe_draft=attached_recipe_draft,
        intent=intent,
    )

    with session_scope() as session:
        thread = get_thread(session, thread_id)
        if thread is None:
            raise ValueError("Assistant thread not found")

        attached_recipe_payload = request.attached_recipe_draft
        if attached_recipe_payload is None and request.attached_recipe_id:
            attached_recipe = get_recipe(session, request.attached_recipe_id)
            if attached_recipe is not None:
                attached_recipe_payload = RecipePayload.model_validate(recipe_payload(session, attached_recipe))

        user_message = create_message(
            session,
            thread=thread,
            role="user",
            status="completed",
            content_markdown=request.text.strip(),
            attached_recipe_id=request.attached_recipe_id,
        )
        assistant_message = create_message(
            session,
            thread=thread,
            role="assistant",
            status="streaming",
            attached_recipe_id=request.attached_recipe_id,
        )
        conversation = [
            assistant_message_payload(message)
            for message in thread.messages
            if message.id != assistant_message.id
        ]
        user_settings = profile_settings_map(session)
        thread_title = thread.title
        existing_provider_thread_id = thread.provider_thread_id or None
        user_message_payload_value = assistant_message_payload(user_message)
        assistant_message_id = assistant_message.id

    try:
        result = run_assistant_turn(
            settings=settings,
            user_settings=user_settings,
            thread_title=thread_title,
            conversation=conversation,
            request=request,
            attached_recipe=attached_recipe_payload,
            existing_provider_thread_id=existing_provider_thread_id,
        )
    except Exception as exc:
        detail = str(exc) or "Assistant response failed."
        with session_scope() as session:
            thread = get_thread(session, thread_id)
            live_message = session.get(AssistantMessage, assistant_message_id)
            if thread is not None and live_message is not None:
                update_assistant_message(
                    thread,
                    live_message,
                    status="failed",
                    content_markdown="",
                    error=detail,
                )
        raise ValueError(detail) from exc

    with session_scope() as session:
        thread = get_thread(session, thread_id)
        live_message = session.get(AssistantMessage, assistant_message_id)
        if thread is None or live_message is None:
            raise ValueError("Assistant thread state disappeared during response.")
        if result.provider_thread_id:
            thread.provider_thread_id = result.provider_thread_id
        update_assistant_message(
            thread,
            live_message,
            status="completed",
            content_markdown=result.envelope.assistant_markdown,
            recipe_draft=result.envelope.recipe_draft,
        )
        session.add(
            AIRun(
                week_id=None,
                run_type="assistant_turn",
                model=result.target.model,
                prompt=request.text,
                status="completed",
                request_payload=json.dumps(
                    {
                        "thread_id": thread_id,
                        "message_id": live_message.id,
                        "intent": request.intent,
                        "attached_recipe_id": request.attached_recipe_id,
                        "target": result.target.as_payload(),
                    }
                ),
                response_payload=result.envelope.model_dump_json(),
            )
        )
        return _json_ready(
            {
                "thread": assistant_thread_payload(thread),
                "user_message": user_message_payload_value,
                "assistant_message": assistant_message_payload(live_message),
                "target": result.target.as_payload(),
            }
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the SimmerSmith MCP server.")
    parser.add_argument("--transport", choices=["stdio", "streamable-http"], default="stdio")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--path", default="/mcp")
    parser.add_argument(
        "--bearer-token",
        default="",
        help="Optional static bearer token for streamable-http mode. Ignored for stdio mode.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.transport == "streamable-http":
        auth = None
        token_verifier = None
        if args.bearer_token.strip():
            auth = AuthSettings(
                issuer_url=f"http://{args.host}:{args.port}",
                resource_server_url=f"http://{args.host}:{args.port}{args.path}",
                required_scopes=[],
            )
            token_verifier = StaticBearerTokenVerifier(args.bearer_token.strip())
        http_mcp = FastMCP(
            name=mcp.name,
            instructions=mcp.instructions,
            tools=mcp._tool_manager.list_tools(),
            host=args.host,
            port=args.port,
            streamable_http_path=args.path,
            lifespan=lifespan,
            auth=auth,
            token_verifier=token_verifier,
        )
        http_mcp.run(transport="streamable-http")
        return
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
