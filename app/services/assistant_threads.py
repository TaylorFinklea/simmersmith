from __future__ import annotations

import json

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from app.models import AssistantMessage, AssistantThread, Recipe, utcnow
from app.schemas import RecipePayload


def list_threads(session: Session) -> list[AssistantThread]:
    return session.scalars(
        select(AssistantThread)
        .where(AssistantThread.archived_at.is_(None))
        .order_by(AssistantThread.updated_at.desc(), AssistantThread.created_at.desc())
    ).all()


def get_thread(session: Session, thread_id: str) -> AssistantThread | None:
    return session.scalar(
        select(AssistantThread)
        .options(selectinload(AssistantThread.messages))
        .where(AssistantThread.id == thread_id, AssistantThread.archived_at.is_(None))
    )


def create_thread(session: Session, title: str = "") -> AssistantThread:
    thread = AssistantThread(title=title.strip())
    session.add(thread)
    session.flush()
    return thread


def archive_thread(session: Session, thread: AssistantThread) -> None:
    timestamp = utcnow()
    thread.archived_at = timestamp
    thread.updated_at = timestamp


def create_message(
    session: Session,
    *,
    thread: AssistantThread,
    role: str,
    status: str,
    content_markdown: str = "",
    recipe_draft: RecipePayload | None = None,
    attached_recipe_id: str | None = None,
    error: str = "",
) -> AssistantMessage:
    message = AssistantMessage(
        thread=thread,
        role=role,
        status=status,
        content_markdown=content_markdown,
        recipe_draft_json=recipe_draft.model_dump_json() if recipe_draft is not None else "",
        attached_recipe_id=attached_recipe_id,
        error=error,
    )
    session.add(message)
    session.flush()
    refresh_thread_metadata(thread)
    return message


def update_assistant_message(
    thread: AssistantThread,
    message: AssistantMessage,
    *,
    status: str,
    content_markdown: str,
    recipe_draft: RecipePayload | None = None,
    error: str = "",
) -> None:
    message.status = status
    message.content_markdown = content_markdown
    message.recipe_draft_json = recipe_draft.model_dump_json() if recipe_draft is not None else ""
    message.error = error
    message.completed_at = utcnow() if status in {"completed", "failed"} else None
    refresh_thread_metadata(thread)


def refresh_thread_metadata(thread: AssistantThread) -> None:
    latest_message = thread.messages[-1] if thread.messages else None
    if not thread.title.strip():
        first_user_message = next((message for message in thread.messages if message.role == "user"), None)
        if first_user_message is not None:
            thread.title = summarize_text(first_user_message.content_markdown, 60) or "New Assistant Chat"
        else:
            thread.title = "New Assistant Chat"

    if latest_message is None:
        thread.preview = ""
    else:
        preview_source = latest_message.content_markdown
        if not preview_source and latest_message.recipe_draft_json:
            try:
                preview_source = RecipePayload.model_validate_json(latest_message.recipe_draft_json).name
            except Exception:
                preview_source = "Recipe draft"
        thread.preview = summarize_text(preview_source, 120)
    thread.updated_at = utcnow()


def resolve_attached_recipe(
    session: Session,
    attached_recipe_id: str | None,
    attached_recipe_draft: RecipePayload | None,
) -> tuple[Recipe | None, RecipePayload | None]:
    attached_recipe = None
    if attached_recipe_id:
        attached_recipe = session.get(Recipe, attached_recipe_id)
    return attached_recipe, attached_recipe_draft


def summarize_text(value: str, limit: int) -> str:
    collapsed = " ".join((value or "").strip().split())
    if len(collapsed) <= limit:
        return collapsed
    return f"{collapsed[: max(limit - 1, 0)].rstrip()}…"


def recipe_draft_json(recipe_draft: RecipePayload | None) -> str:
    if recipe_draft is None:
        return ""
    return json.dumps(recipe_draft.model_dump(mode="json"), separators=(",", ":"))
