"""Bug-bash 2026-06-13 — assistant-ai lane fixes.

#20  page_context.week_id is validated against the caller's household before
     it becomes AIRun.week_id, so a bogus/non-owned id no longer FK-violates
     the final persist and marks an otherwise-completed turn as failed.
T7   the streaming tool loop + non-streaming JSON indexing in assistant_ai
     wrap provider HTTP/shape errors as a clean RuntimeError (no leaked
     provider URL), and assistant.api / recipe_search_ai sanitize the
     detail surfaced to the client.
"""
from __future__ import annotations

import httpx
import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import session_scope
from app.models import AIRun
from app.services.assistant_ai import (
    AssistantExecutionTarget,
    AssistantProviderEnvelope,
    AssistantTurnResult,
    OpenAIAdapter,
    _run_provider_tool_loop,
    run_direct_provider,
)


# ── #20 — a bogus page_context.week_id is dropped, not persisted as a FK ──


def _ok_turn_result() -> AssistantTurnResult:
    return AssistantTurnResult(
        target=AssistantExecutionTarget(
            provider_kind="direct", source="test", provider_name="openai", model="test-model"
        ),
        prompt="system",
        raw_output="{}",
        envelope=AssistantProviderEnvelope(assistant_markdown="Here is a tip."),
        provider_thread_id=None,
        tool_calls=[],
    )


def test_bogus_page_context_week_id_completes_and_persists_null_week(client, monkeypatch) -> None:
    def fake_run_assistant_turn(**_: object) -> AssistantTurnResult:
        return _ok_turn_result()

    monkeypatch.setattr("app.api.assistant.run_assistant_turn", fake_run_assistant_turn)

    create = client.post("/api/assistant/threads", json={"title": "Chat"})
    assert create.status_code == 200, create.text
    thread_id = create.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={
            "text": "any tips?",
            "intent": "general",
            # A week id that does not exist / is not owned by the caller.
            "page_context": {"week_id": "week-does-not-exist", "page_type": "week"},
        },
    ) as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())

    # Pre-fix: the AIRun insert FK-violated on flush(), the turn was caught as
    # a generic failure, and an assistant.error was emitted. Post-fix the turn
    # completes cleanly.
    assert "event: assistant.completed" in body
    assert "event: assistant.error" not in body

    detail = client.get(f"/api/assistant/threads/{thread_id}").json()
    statuses = [m["status"] for m in detail["messages"] if m["role"] == "assistant"]
    assert statuses == ["completed"]

    # The dangling week id was dropped to NULL rather than persisted as a FK.
    with session_scope() as session:
        runs = session.scalars(select(AIRun)).all()
        week_ids = [r.week_id for r in runs]
    assert week_ids and all(wid is None for wid in week_ids)


def test_valid_page_context_week_id_is_kept(client, monkeypatch) -> None:
    """A real, owned week id still flows through to AIRun.week_id."""

    def fake_run_assistant_turn(**_: object) -> AssistantTurnResult:
        return _ok_turn_result()

    monkeypatch.setattr("app.api.assistant.run_assistant_turn", fake_run_assistant_turn)

    week = client.post("/api/weeks", json={"week_start": "2026-09-21", "notes": ""}).json()
    week_id = week.get("week_id") or week["id"]

    create = client.post("/api/assistant/threads", json={"title": "Chat"})
    thread_id = create.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={
            "text": "plan it",
            "intent": "general",
            "page_context": {"week_id": week_id, "page_type": "week"},
        },
    ) as response:
        assert response.status_code == 200
        "".join(response.iter_text())

    with session_scope() as session:
        runs = session.scalars(select(AIRun)).all()
        week_ids = [r.week_id for r in runs]
    assert week_id in week_ids


# ── T7 — streaming provider errors wrap as a clean RuntimeError (no URL) ──


class _RaisingStream:
    """A stream whose raise_for_status raises an httpx status error carrying
    the provider URL — mirrors what httpx does on a 401/429/5xx."""

    def iter_lines(self):
        yield from ()

    def raise_for_status(self) -> None:
        request = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
        response = httpx.Response(429, request=request)
        raise httpx.HTTPStatusError(
            "Client error '429 Too Many Requests' for url "
            "'https://api.openai.com/v1/chat/completions'",
            request=request,
            response=response,
        )

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class _RaisingClient:
    def stream(self, *args, **kwargs):  # noqa: ARG002
        return _RaisingStream()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def _openai_adapter() -> OpenAIAdapter:
    target = AssistantExecutionTarget(
        provider_kind="direct", source="test", provider_name="openai", model="test-model"
    )
    return OpenAIAdapter(
        target=target,
        settings=get_settings(),
        user_settings={},
        system_prompt="planning system",
        conversation=[],
        user_text="plan",
    )


def test_streaming_provider_http_error_wraps_without_leaking_url(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.assistant_ai.httpx.Client",
        lambda *a, **k: _RaisingClient(),  # noqa: ARG005
    )
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key",
        lambda *a, **k: "sk-fake",  # noqa: ARG005
    )

    adapter = _openai_adapter()
    target = adapter.target

    def tool_runner(name: str, args: dict):  # noqa: ARG001
        raise AssertionError("tool_runner must not fire when the stream itself errors")

    with pytest.raises(RuntimeError) as excinfo:
        _run_provider_tool_loop(
            adapter=adapter,
            target=target,
            settings=get_settings(),
            tool_runner=tool_runner,
            on_event=None,
            abort_event=None,
        )

    # Pre-fix the bare httpx.HTTPStatusError escaped the worker and its str
    # leaked the endpoint. Post-fix it's a clean RuntimeError with no URL.
    message = str(excinfo.value)
    assert "api.openai.com" not in message
    assert "http" not in message.lower()


# ── T7 — non-streaming JSON indexing wraps a bad shape as RuntimeError ──


class _ShapeResponse:
    """A 200 response whose JSON body is missing the expected keys."""

    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict[str, object]:
        return {"unexpected": "shape"}


class _ShapeClient:
    def post(self, *args, **kwargs):  # noqa: ARG002
        return _ShapeResponse()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def test_non_streaming_bad_shape_wraps_as_runtimeerror(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.assistant_ai.httpx.Client",
        lambda *a, **k: _ShapeClient(),  # noqa: ARG005
    )
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key",
        lambda *a, **k: "sk-fake",  # noqa: ARG005
    )

    target = AssistantExecutionTarget(
        provider_kind="direct", source="test", provider_name="openai", model="test-model"
    )
    # Pre-fix: payload["choices"][0] raised a bare KeyError -> generic 500.
    with pytest.raises(RuntimeError):
        run_direct_provider(
            target=target, settings=get_settings(), user_settings={}, prompt="hi"
        )


# ── T7 — recipe web-search provider error message omits the provider URL ──


class _SearchRaisingResponse:
    def raise_for_status(self) -> None:
        request = httpx.Request("POST", "https://api.openai.com/v1/responses")
        response = httpx.Response(401, request=request)
        raise httpx.HTTPStatusError(
            "Client error '401 Unauthorized' for url 'https://api.openai.com/v1/responses'",
            request=request,
            response=response,
        )

    def json(self) -> dict[str, object]:  # pragma: no cover - not reached
        return {}


class _SearchRaisingClient:
    def post(self, *args, **kwargs):  # noqa: ARG002
        return _SearchRaisingResponse()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def test_recipe_search_http_error_does_not_leak_url(monkeypatch) -> None:
    from app.services import recipe_search_ai

    monkeypatch.setattr(
        recipe_search_ai.httpx, "Client", lambda *a, **k: _SearchRaisingClient()  # noqa: ARG005
    )
    monkeypatch.setattr(
        recipe_search_ai, "resolve_direct_api_key", lambda *a, **k: "sk-fake"  # noqa: ARG005
    )

    target = recipe_search_ai._Target(provider="openai", model="test-model")
    with pytest.raises(RuntimeError) as excinfo:
        recipe_search_ai._search_openai(
            query="best waffles",
            target=target,
            settings=get_settings(),
            user_settings={},
        )

    message = str(excinfo.value)
    assert "api.openai.com" not in message
    assert "http" not in message.lower()


# ── T7 — the SSE-error sanitizer strips provider URLs ──


def test_sanitize_error_detail_strips_urls() -> None:
    from app.api.assistant import _sanitize_error_detail

    leaked = (
        "Client error '500' for url 'https://api.openai.com/v1/chat/completions' "
        "body=secret"
    )
    cleaned = _sanitize_error_detail(leaked)
    assert "api.openai.com" not in cleaned
    assert "https://" not in cleaned

    # A URL-only message collapses to the safe fallback.
    only_url = _sanitize_error_detail("https://api.anthropic.com/v1/messages")
    assert "api.anthropic.com" not in only_url
    assert only_url

    # Plain messages pass through unchanged.
    assert _sanitize_error_detail("Tool limit reached.") == "Tool limit reached."


def test_assistant_error_sse_detail_is_sanitized(client, monkeypatch) -> None:
    """An exception whose message embeds a provider URL must not leak that
    URL into the assistant.error SSE event."""

    def boom(**_: object) -> AssistantTurnResult:
        raise RuntimeError(
            "boom for url 'https://api.openai.com/v1/chat/completions'"
        )

    monkeypatch.setattr("app.api.assistant.run_assistant_turn", boom)

    create = client.post("/api/assistant/threads", json={"title": "Chat"})
    thread_id = create.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={"text": "hi", "intent": "general"},
    ) as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())

    assert "event: assistant.error" in body
    # The leaked URL must be redacted from the client-facing error frame.
    assert "api.openai.com" not in body
