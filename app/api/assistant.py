from __future__ import annotations

import asyncio
import json
import logging
import queue
import threading
from collections.abc import AsyncIterator

from fastapi import APIRouter, Depends, HTTPException, Request, Response
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
    persist_streaming_content,
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

# How often the SSE endpoint flushes accumulated streamed text to the DB.
# Tunable for tests (monkeypatch to 0 to flush on every delta).
STREAM_PERSIST_INTERVAL_SECONDS = 0.5


async def stream_test_response() -> StreamingResponse:
    """Unauthenticated SSE smoke test. Emits 20 pre-canned delta events
    spaced 100ms apart so we can confirm the server + fly-proxy + curl
    pipeline streams incrementally without involving OpenAI or the tool
    loop. If curl sees chunks arrive one-by-one, the transport is good
    and any perceived buffering lives elsewhere (OpenAI granularity, iOS
    URLSession, or SwiftUI frame coalescing).

    Registered as a public route directly on the FastAPI app in main.py.
    """

    async def gen() -> AsyncIterator[str]:
        yield ":" + (" " * 2048) + "\n\n"
        for index in range(20):
            yield encode_sse("assistant.delta", {"delta": f"tok{index} "})
            await asyncio.sleep(0.1)
        yield encode_sse("assistant.completed", {"total": 20})

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


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
    request: Request,
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

    # Effective context comes from per-message page_context (Nebular-style)
    # with fallback to the thread's linked_week_id for older clients.
    page_context = payload.page_context
    page_context_week_id = page_context.week_id if page_context else None
    effective_linked_week_id = page_context_week_id or thread.linked_week_id
    # We treat ANY message that carries a week_id (via page_context or thread
    # linkage) as a planning turn — that's when the tool loop fires.
    thread_kind = (
        "planning"
        if effective_linked_week_id or thread.thread_kind == "planning"
        else thread.thread_kind
    )
    linked_week_id = effective_linked_week_id
    planning_context_text = _planning_context_text(
        session,
        current_user.id,
        linked_week_id,
        page_context=page_context,
    )

    initial_thread_payload = assistant_thread_summary_payload(thread)
    initial_user_payload = assistant_message_payload(user_message)
    # Empty assistant row so tool_call events have an anchor before any
    # content delta arrives. iOS appendAssistantToolCall requires a
    # role="assistant" message to attach the card to — without this the
    # card gets silently dropped when the AI goes straight to a tool.
    initial_assistant_payload = assistant_message_payload(assistant_message)
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
        # 2KB padding comment to push past any intermediate proxy's initial
        # buffer threshold. SSE comment lines start with ":". Harmless to
        # clients but forces fly-proxy to flush its read-ahead buffer so
        # subsequent small frames (80-200 bytes each) aren't held up.
        yield ":" + (" " * 2048) + "\n\n"
        yield encode_sse("thread.updated", initial_thread_payload)
        yield encode_sse("user_message.created", initial_user_payload)
        yield encode_sse("assistant.message.created", initial_assistant_payload)

        event_queue: "queue.Queue[tuple[str, dict[str, object]] | None]" = queue.Queue()
        # Signaled when the client disconnects so the tool loop can exit
        # between OpenAI chunks / tool calls instead of running to completion
        # spending tokens on a reply nobody will read.
        abort_event = threading.Event()

        def on_event(event: str, data: dict[str, object]) -> None:
            # The tool loop doesn't know the assistant_message_id; inject it
            # here so the iOS client can attribute deltas to the correct
            # message bubble.
            if event == "assistant.delta" and "message_id" not in data:
                data["message_id"] = assistant_message_id
            event_queue.put((event, data))

        def tool_runner(name: str, args: dict) -> AssistantToolResult:
            with session_scope() as tool_session:
                result = run_tool(
                    name,
                    session=tool_session,
                    user_id=user_id,
                    linked_week_id=linked_week_id,
                    args=args,
                    settings=settings,
                    on_event=on_event if use_tools else None,
                )
            return result

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
                    abort_event=abort_event,
                )
            finally:
                event_queue.put(None)

        task = asyncio.create_task(asyncio.to_thread(worker))

        async def _watch_disconnect() -> None:
            # Poll the Starlette receive channel so we can fire the abort
            # event as soon as the client goes away. ~1s cadence keeps
            # overhead low; the tool loop checks the flag between OpenAI
            # chunks anyway, so sub-second precision isn't useful.
            while not task.done():
                try:
                    if await request.is_disconnected():
                        abort_event.set()
                        return
                except Exception:
                    return
                await asyncio.sleep(1.0)

        disconnect_watcher = asyncio.create_task(_watch_disconnect())

        # Track streamed text so we can periodically flush it to the DB.
        # Without this, closing + reopening the assistant sheet mid-turn
        # shows an empty bubble until the whole turn completes.
        streamed_text = ""
        last_persist_at = 0.0

        def _flush_streamed_content() -> None:
            nonlocal last_persist_at
            if not streamed_text:
                return
            try:
                with session_scope() as persist_session:
                    persist_streaming_content(
                        persist_session, assistant_message_id, streamed_text
                    )
            except Exception:
                logger.exception(
                    "Failed to persist streamed deltas for message %s",
                    assistant_message_id,
                )
            last_persist_at = asyncio.get_event_loop().time()

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
                if event_name == "assistant.delta":
                    delta_piece = str(data.get("delta", ""))
                    if delta_piece:
                        streamed_text += delta_piece
                        now = asyncio.get_event_loop().time()
                        if now - last_persist_at >= STREAM_PERSIST_INTERVAL_SECONDS:
                            _flush_streamed_content()
                yield encode_sse(event_name, data)

            # Final flush before `update_assistant_message` overwrites with
            # the envelope text — harmless if they're equal.
            _flush_streamed_content()

            result = await task
            final_status = "cancelled" if result.cancelled else "completed"
            run_status = "cancelled" if result.cancelled else "completed"
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
                    status=final_status,
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
                        status=run_status,
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
                                "cancelled": result.cancelled,
                            }
                        ),
                        response_payload=result.envelope.model_dump_json(),
                    )
                )
                stream_session.flush()
                message_payload = assistant_message_payload(live_message)
                thread_payload = assistant_thread_summary_payload(live_thread)

            if result.cancelled:
                # Client is already gone; these yields will just no-op into a
                # closed TCP stream. Still try them so any proxy caching a
                # partial response sees a clean terminator.
                yield encode_sse("thread.updated", thread_payload)
                yield encode_sse(
                    "assistant.cancelled",
                    {
                        "message_id": assistant_message_id,
                        "content_markdown": result.envelope.assistant_markdown,
                    },
                )
            else:
                if not result.streamed_deltas:
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
                        content_markdown=f"Assistant request failed: {detail}",
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
                {"message_id": assistant_message_id, "detail": detail},
            )
        finally:
            # Always tear down the disconnect watcher so it doesn't outlive
            # the stream (prevents a leaking polling coroutine per request).
            disconnect_watcher.cancel()
            try:
                await disconnect_watcher
            except (asyncio.CancelledError, Exception):
                pass

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            # Disable any intermediate buffering between uvicorn → fly-proxy
            # → client. Without these, Fly's proxy can hold chunks for
            # hundreds of ms before flushing, which looks like "not
            # streaming" in the iOS UI. `X-Accel-Buffering` is the nginx
            # signal; other proxies honor it too.
            "Cache-Control": "no-cache, no-transform",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


def _planning_context_text(
    session: Session,
    user_id: str,
    linked_week_id: str | None,
    *,
    page_context: object | None = None,
) -> str:
    """Build a compact week snapshot + page context for the system prompt."""
    page_lines: list[str] = []
    if page_context is not None:
        # AssistantPageContext model; dump with pydantic to tolerate any type.
        try:
            data = page_context.model_dump() if hasattr(page_context, "model_dump") else dict(page_context)
        except Exception:
            data = {}
        if data.get("page_type"):
            label = data.get("page_label") or ""
            page_lines.append(
                f"User is looking at: {data.get('page_type')}"
                + (f" — {label}" if label else "")
            )
        if data.get("recipe_name") or data.get("recipe_id"):
            page_lines.append(
                f"Focused recipe: {data.get('recipe_name') or ''} (id={data.get('recipe_id') or ''})"
            )
        if data.get("focus_day_name") or data.get("focus_date"):
            page_lines.append(
                f"Focused day: {data.get('focus_day_name') or ''} ({data.get('focus_date') or ''})"
            )
        if data.get("brief_summary"):
            page_lines.append(f"Page summary: {data['brief_summary']}")

    week = None
    if linked_week_id:
        week = get_week(session, user_id, linked_week_id)
    if week is None:
        week = get_current_week(session, user_id)
    if week is None:
        joined = ("\n".join(page_lines) + "\n") if page_lines else ""
        return joined + "Current week: none. Ask the user to create one before editing."

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
    return "\n".join(page_lines + lines)


def encode_sse(event: str, payload: dict[str, object]) -> str:
    encoded = jsonable_encoder(payload)
    return f"event: {event}\ndata: {json.dumps(encoded)}\n\n"


def chunk_text(value: str, size: int = 180) -> list[str]:
    collapsed = value.strip()
    if not collapsed:
        return []
    return [collapsed[index : index + size] for index in range(0, len(collapsed), size)]
