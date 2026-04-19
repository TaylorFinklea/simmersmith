from __future__ import annotations

import asyncio
import json
import logging
import queue
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.encoders import jsonable_encoder
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import Settings, get_settings
from app.db import get_session, session_scope
from app.models import AIRun, AssistantMessage
from app.schemas import (
    AssistantRespondRequest,
    AssistantThreadCreateRequest,
    AssistantThreadOut,
    AssistantThreadSummaryOut,
)
from app.services.ai import profile_settings_map
from app.services.assistant_ai import AssistantTurnResult, run_assistant_turn
from app.services.assistant_threads import (
    archive_thread,
    create_message,
    create_thread,
    get_thread,
    list_threads,
    update_assistant_message,
)
from app.services.assistant_tools import AssistantToolResult, run_tool
from app.services.presenters import (
    assistant_message_payload,
    assistant_thread_payload,
    assistant_thread_summary_payload,
    recipe_payload,
    week_payload,
)
from app.services.recipes import get_recipe
from app.services.weeks import get_current_week, get_week
from app.schemas import RecipePayload

logger = logging.getLogger(__name__)


router = APIRouter(prefix="/api/assistant", tags=["assistant"])


@router.get("/threads", response_model=list[AssistantThreadSummaryOut])
def list_threads_route(
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> list[dict[str, object]]:
    return [assistant_thread_summary_payload(thread) for thread in list_threads(session, current_user.id)]


@router.post("/threads", response_model=AssistantThreadSummaryOut)
def create_thread_route(
    payload: AssistantThreadCreateRequest,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    linked_week_id = payload.linked_week_id
    if linked_week_id:
        linked_week = get_week(session, current_user.id, linked_week_id)
        if linked_week is None:
            raise HTTPException(status_code=404, detail="Linked week not found.")

    thread = create_thread(
        session,
        current_user.id,
        title=payload.title,
        thread_kind=payload.thread_kind,
        linked_week_id=linked_week_id,
    )
    session.commit()
    session.refresh(thread)
    return assistant_thread_summary_payload(thread)


@router.get("/threads/{thread_id}", response_model=AssistantThreadOut)
def thread_detail_route(
    thread_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> dict[str, object]:
    thread = get_thread(session, current_user.id, thread_id)
    if thread is None:
        raise HTTPException(status_code=404, detail="Assistant thread not found")
    return assistant_thread_payload(thread)


@router.delete("/threads/{thread_id}", status_code=204)
def delete_thread_route(
    thread_id: str,
    session: Session = Depends(get_session),
    current_user: CurrentUser = Depends(get_current_user),
) -> Response:
    thread = get_thread(session, current_user.id, thread_id)
    if thread is None:
        raise HTTPException(status_code=404, detail="Assistant thread not found")
    archive_thread(session, thread)
    session.commit()
    return Response(status_code=204)


@router.post("/threads/{thread_id}/respond")
async def respond_route(
    thread_id: str,
    payload: AssistantRespondRequest,
    session: Session = Depends(get_session),
    settings: Settings = Depends(get_settings),
    current_user: CurrentUser = Depends(get_current_user),
) -> StreamingResponse:
    thread = get_thread(session, current_user.id, thread_id)
    if thread is None:
        raise HTTPException(status_code=404, detail="Assistant thread not found")

    attached_recipe_payload = payload.attached_recipe_draft
    if attached_recipe_payload is None and payload.attached_recipe_id:
        attached_recipe = get_recipe(session, current_user.id, payload.attached_recipe_id)
        if attached_recipe is not None:
            attached_recipe_payload = RecipePayload.model_validate(recipe_payload(session, attached_recipe))

    user_message = create_message(
        session,
        thread=thread,
        role="user",
        status="completed",
        content_markdown=payload.text.strip(),
        attached_recipe_id=payload.attached_recipe_id,
    )
    assistant_message = create_message(
        session,
        thread=thread,
        role="assistant",
        status="streaming",
        attached_recipe_id=payload.attached_recipe_id,
    )
    session.commit()

    thread_kind = thread.thread_kind
    linked_week_id = thread.linked_week_id
    planning_context_text = _planning_context_text(session, current_user.id, linked_week_id)

    initial_thread_payload = assistant_thread_summary_payload(thread)
    initial_user_payload = assistant_message_payload(user_message)
    conversation = [
        assistant_message_payload(message)
        for message in thread.messages
        if message.id != assistant_message.id
    ]
    user_settings = profile_settings_map(session, current_user.id)
    use_tools = thread_kind == "planning"
    user_id = current_user.id
    assistant_message_id = assistant_message.id

    async def event_stream() -> AsyncIterator[str]:
        yield encode_sse("thread.updated", initial_thread_payload)
        yield encode_sse("user_message.created", initial_user_payload)

        event_queue: "queue.Queue[tuple[str, dict[str, object]] | None]" = queue.Queue()

        def tool_runner(name: str, args: dict) -> AssistantToolResult:
            with session_scope() as tool_session:
                result = run_tool(
                    name,
                    session=tool_session,
                    user_id=user_id,
                    linked_week_id=linked_week_id,
                    args=args,
                    settings=settings,
                )
            return result

        def on_event(event: str, data: dict[str, object]) -> None:
            event_queue.put((event, data))

        def worker() -> AssistantTurnResult:
            try:
                return run_assistant_turn(
                    settings=settings,
                    user_settings=user_settings,
                    thread_title=thread.title,
                    conversation=conversation,
                    request=payload,
                    attached_recipe=attached_recipe_payload,
                    existing_provider_thread_id=thread.provider_thread_id or None,
                    tool_runner=tool_runner if use_tools else None,
                    on_event=on_event if use_tools else None,
                    planning_context=planning_context_text if use_tools else None,
                )
            finally:
                event_queue.put(None)

        task = asyncio.create_task(asyncio.to_thread(worker))

        try:
            while True:
                try:
                    item = await asyncio.wait_for(
                        asyncio.to_thread(event_queue.get), timeout=1.0
                    )
                except asyncio.TimeoutError:
                    if task.done():
                        break
                    continue
                if item is None:
                    break
                event_name, data = item
                yield encode_sse(event_name, data)

            result = await task
            with session_scope() as stream_session:
                live_thread = get_thread(stream_session, user_id, thread_id)
                live_message = stream_session.get(AssistantMessage, assistant_message_id)
                if live_thread is None or live_message is None:
                    raise RuntimeError("Assistant thread state disappeared during response.")
                if result.provider_thread_id:
                    live_thread.provider_thread_id = result.provider_thread_id
                update_assistant_message(
                    live_thread,
                    live_message,
                    status="completed",
                    content_markdown=result.envelope.assistant_markdown,
                    recipe_draft=result.envelope.recipe_draft,
                    tool_calls=result.tool_calls,
                )
                stream_session.add(
                    AIRun(
                        user_id=user_id,
                        week_id=linked_week_id,
                        run_type="assistant_turn" if not use_tools else "assistant_planning_turn",
                        model=result.target.model,
                        prompt=payload.text,
                        status="completed",
                        request_payload=json.dumps(
                            {
                                "thread_id": thread_id,
                                "message_id": live_message.id,
                                "intent": payload.intent,
                                "attached_recipe_id": payload.attached_recipe_id,
                                "target": result.target.as_payload(),
                                "thread_kind": thread_kind,
                                "linked_week_id": linked_week_id,
                                "tool_calls": result.tool_calls,
                            }
                        ),
                        response_payload=result.envelope.model_dump_json(),
                    )
                )
                stream_session.flush()
                message_payload = assistant_message_payload(live_message)
                thread_payload = assistant_thread_summary_payload(live_thread)

            for chunk in chunk_text(result.envelope.assistant_markdown):
                yield encode_sse("assistant.delta", {"message_id": assistant_message_id, "delta": chunk})
            if message_payload["recipe_draft"] is not None:
                yield encode_sse(
                    "assistant.recipe_draft",
                    {"message_id": assistant_message_id, "draft": message_payload["recipe_draft"]},
                )
            yield encode_sse("thread.updated", thread_payload)
            yield encode_sse("assistant.completed", message_payload)
        except Exception as exc:
            detail = str(exc) or "Assistant response failed."
            logger.exception("Assistant turn failed for thread %s", thread_id)
            with session_scope() as stream_session:
                live_thread = get_thread(stream_session, user_id, thread_id)
                live_message = stream_session.get(AssistantMessage, assistant_message_id)
                if live_thread is not None and live_message is not None:
                    update_assistant_message(
                        live_thread,
                        live_message,
                        status="failed",
                        content_markdown="Assistant request failed. Please try again.",
                        error=detail,
                    )
                stream_session.add(
                    AIRun(
                        user_id=user_id,
                        week_id=linked_week_id,
                        run_type="assistant_turn",
                        model="assistant-error",
                        prompt=payload.text,
                        status="failed",
                        request_payload=json.dumps(
                            {
                                "thread_id": thread_id,
                                "message_id": assistant_message_id,
                                "intent": payload.intent,
                                "attached_recipe_id": payload.attached_recipe_id,
                                "thread_kind": thread_kind,
                                "linked_week_id": linked_week_id,
                            }
                        ),
                        response_payload="{}",
                        error=detail,
                    )
                )
            yield encode_sse(
                "assistant.error",
                {"message_id": assistant_message_id, "detail": "Assistant request failed. Please try again."},
            )

    return StreamingResponse(event_stream(), media_type="text/event-stream")


def _planning_context_text(session: Session, user_id: str, linked_week_id: str | None) -> str:
    """Build a compact week snapshot for the planning system prompt."""
    week = None
    if linked_week_id:
        week = get_week(session, user_id, linked_week_id)
    if week is None:
        week = get_current_week(session, user_id)
    if week is None:
        return "Current week: none. Ask the user to create one before editing."

    payload = week_payload(week, session=session) or {}
    meals = payload.get("meals") or []
    dietary_goal = payload.get("dietary_goal")
    lines: list[str] = []
    lines.append(f"Current week: {payload.get('week_start')} (id={payload.get('week_id')}, status={payload.get('status')}).")
    if isinstance(dietary_goal, dict):
        lines.append(
            "Dietary goal: "
            f"{dietary_goal.get('goal_type')} at {dietary_goal.get('daily_calories')} kcal/day "
            f"(P{dietary_goal.get('protein_g')}/C{dietary_goal.get('carbs_g')}/F{dietary_goal.get('fat_g')})."
        )
    else:
        lines.append("Dietary goal: none set.")

    if not isinstance(meals, list) or not meals:
        lines.append("Meals: none yet.")
    else:
        lines.append("Meals (up to 21 over 7 days):")
        for meal in meals[:21]:
            if not isinstance(meal, dict):
                continue
            tag = " ✓" if meal.get("approved") else ""
            lines.append(
                f"  - {meal.get('day_name')} {meal.get('slot')}: {meal.get('recipe_name')} "
                f"(meal_id={meal.get('meal_id')}){tag}"
            )
    lines.append("")
    return "\n".join(lines)


def encode_sse(event: str, payload: dict[str, object]) -> str:
    encoded = jsonable_encoder(payload)
    return f"event: {event}\ndata: {json.dumps(encoded)}\n\n"


def chunk_text(value: str, size: int = 180) -> list[str]:
    collapsed = value.strip()
    if not collapsed:
        return []
    return [collapsed[index : index + size] for index in range(0, len(collapsed), size)]
