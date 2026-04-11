from __future__ import annotations

import json
from typing import Any

from . import mcp
from ._helpers import _json_ready, _settings

from app.db import session_scope
from app.models import AIRun, AssistantMessage
from app.schemas import (
    AssistantRespondRequest,
    AssistantThreadCreateRequest,
    RecipePayload,
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
from app.services.presenters import (
    assistant_message_payload,
    assistant_thread_payload,
    assistant_thread_summary_payload,
    recipe_payload,
)
from app.services.recipes import get_recipe


@mcp.tool(description="List assistant threads.")
def assistant_list_threads() -> list[dict[str, Any]]:
    user_id = _settings().local_user_id
    with session_scope() as session:
        return _json_ready(
            [assistant_thread_summary_payload(thread) for thread in list_threads(session, user_id)]
        )


@mcp.tool(description="Create a new assistant thread.")
def assistant_create_thread(title: str = "") -> dict[str, Any]:
    user_id = _settings().local_user_id
    with session_scope() as session:
        payload = AssistantThreadCreateRequest(title=title)
        thread = create_thread(session, user_id, title=payload.title)
        return _json_ready(assistant_thread_summary_payload(thread))


@mcp.tool(description="Get a single assistant thread with all messages.")
def assistant_get_thread(thread_id: str) -> dict[str, Any]:
    user_id = _settings().local_user_id
    with session_scope() as session:
        thread = get_thread(session, user_id, thread_id)
        if thread is None:
            raise ValueError("Assistant thread not found")
        return _json_ready(assistant_thread_payload(thread))


@mcp.tool(description="Archive an assistant thread.")
def assistant_archive_thread(thread_id: str) -> dict[str, Any]:
    user_id = _settings().local_user_id
    with session_scope() as session:
        thread = get_thread(session, user_id, thread_id)
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
    user_id = settings.local_user_id
    request = AssistantRespondRequest(
        text=text,
        attached_recipe_id=attached_recipe_id,
        attached_recipe_draft=attached_recipe_draft,
        intent=intent,
    )

    with session_scope() as session:
        thread = get_thread(session, user_id, thread_id)
        if thread is None:
            raise ValueError("Assistant thread not found")

        attached_recipe_payload = request.attached_recipe_draft
        if attached_recipe_payload is None and request.attached_recipe_id:
            attached_recipe = get_recipe(session, user_id, request.attached_recipe_id)
            if attached_recipe is not None:
                attached_recipe_payload = RecipePayload.model_validate(
                    recipe_payload(session, attached_recipe)
                )

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
        user_settings = profile_settings_map(session, user_id)
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
            thread = get_thread(session, user_id, thread_id)
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
        thread = get_thread(session, user_id, thread_id)
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
                user_id=user_id,
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
