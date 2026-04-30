"""M19 — Anthropic tool-use parity tests for the provider-agnostic loop."""
from __future__ import annotations

import json
from dataclasses import dataclass

import pytest

from app.config import get_settings
from app.schemas import AssistantRespondRequest
from app.services.assistant_ai import (
    AnthropicAdapter,
    AssistantExecutionTarget,
    OpenAIAdapter,
    _run_provider_tool_loop,
    run_assistant_turn,
)
from app.services.assistant_tools import AssistantToolResult


# ---- helpers --------------------------------------------------------------


def _anthropic_event(event_name: str, data: dict[str, object]) -> list[str]:
    """Format one Anthropic SSE event as the lines `iter_lines()` yields.

    Anthropic streams `event: <name>\\ndata: <json>\\n\\n`. `httpx`'s
    `iter_lines()` strips the trailing newline characters and yields the
    blank separator as an empty string; both are needed so the adapter's
    parser dispatches the pending event.
    """
    return [f"event: {event_name}", f"data: {json.dumps(data)}", ""]


def _build_anthropic_stream_lines(
    *,
    text_chunks: list[str] | None = None,
    tool_calls: list[dict[str, object]] | None = None,
    stop_reason: str = "end_turn",
) -> list[str]:
    """Compose a realistic Anthropic SSE stream as a list of `iter_lines` outputs.

    `text_chunks` becomes a single text content block (index 0) emitted
    via `text_delta`s. `tool_calls` is a list of
    `{"id", "name", "input": dict}` entries; each becomes a `tool_use`
    block at consecutive indexes after the text block (or starting at 0
    if no text). The arguments JSON is split into 2 partial chunks to
    exercise the adapter's `input_json_delta` accumulation.
    """
    text_chunks = text_chunks or []
    tool_calls = tool_calls or []
    lines: list[str] = []
    lines += _anthropic_event(
        "message_start",
        {"type": "message_start", "message": {"id": "msg_test", "role": "assistant"}},
    )

    next_index = 0
    if text_chunks:
        lines += _anthropic_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": next_index,
                "content_block": {"type": "text", "text": ""},
            },
        )
        for chunk in text_chunks:
            lines += _anthropic_event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": next_index,
                    "delta": {"type": "text_delta", "text": chunk},
                },
            )
        lines += _anthropic_event(
            "content_block_stop",
            {"type": "content_block_stop", "index": next_index},
        )
        next_index += 1

    for call in tool_calls:
        lines += _anthropic_event(
            "content_block_start",
            {
                "type": "content_block_start",
                "index": next_index,
                "content_block": {
                    "type": "tool_use",
                    "id": call["id"],
                    "name": call["name"],
                    "input": {},
                },
            },
        )
        # Split the arguments JSON into two chunks to verify accumulation.
        args_json = json.dumps(call.get("input", {}))
        split_at = max(1, len(args_json) // 2)
        first = args_json[:split_at]
        rest = args_json[split_at:]
        for partial in (first, rest):
            if not partial:
                continue
            lines += _anthropic_event(
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": next_index,
                    "delta": {"type": "input_json_delta", "partial_json": partial},
                },
            )
        lines += _anthropic_event(
            "content_block_stop",
            {"type": "content_block_stop", "index": next_index},
        )
        next_index += 1

    lines += _anthropic_event(
        "message_delta",
        {"type": "message_delta", "delta": {"stop_reason": stop_reason}},
    )
    lines += _anthropic_event("message_stop", {"type": "message_stop"})
    return lines


@dataclass
class _RecordedRequest:
    url: str
    headers: dict[str, str]
    json: dict[str, object]


class _FakeAnthropicClient:
    """Stateful httpx.Client stand-in for multi-turn Anthropic tests.

    Each `stream()` call pops the next pre-staged stream of SSE lines and
    records the request URL/headers/body for assertions.
    """

    def __init__(self, streams: list[list[str]]) -> None:
        self._streams = list(streams)
        self.requests: list[_RecordedRequest] = []

    def stream(self, method: str, url: str, *, headers: dict[str, str], json: dict):  # noqa: ARG002
        self.requests.append(_RecordedRequest(url=url, headers=dict(headers), json=dict(json)))
        if not self._streams:
            raise AssertionError("FakeAnthropicClient: more requests than staged streams")
        lines = self._streams.pop(0)
        return _FakeLineStream(lines)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class _FakeLineStream:
    def __init__(self, lines: list[str]) -> None:
        self._lines = lines

    def iter_lines(self):
        for line in self._lines:
            yield line

    def raise_for_status(self) -> None:
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def _make_anthropic_target() -> AssistantExecutionTarget:
    return AssistantExecutionTarget(
        provider_kind="direct",
        source="test",
        provider_name="anthropic",
        model="claude-test-model",
    )


# ---- tests ----------------------------------------------------------------


def test_anthropic_planning_thread_invokes_tool(monkeypatch) -> None:
    """A single Anthropic turn that emits a tool_use block routes through
    the same `tool_runner` the OpenAI loop uses, fires the
    `assistant.tool_call` SSE event, and propagates `result.week` as a
    `week.updated` event — matching the OpenAI parity contract.
    """
    # Turn 1: tool_use; turn 2: short text-only response so the loop ends.
    streams = [
        _build_anthropic_stream_lines(
            tool_calls=[
                {"id": "toolu_add_1", "name": "add_meal", "input": {"day_name": "Wed"}}
            ],
            stop_reason="tool_use",
        ),
        _build_anthropic_stream_lines(text_chunks=["Done."], stop_reason="end_turn"),
    ]
    fake_client = _FakeAnthropicClient(streams)

    monkeypatch.setattr(
        "app.services.assistant_ai.httpx.Client",
        lambda *args, **kwargs: fake_client,  # noqa: ARG005
    )
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key",
        lambda *a, **k: "sk-ant-fake",  # noqa: ARG005
    )

    invocations: list[tuple[str, dict[str, object]]] = []

    def tool_runner(name: str, args: dict[str, object]) -> AssistantToolResult:
        invocations.append((name, args))
        return AssistantToolResult(
            ok=True,
            detail="Added Wed dinner.",
            week={"week_id": "w1", "meals": []},
        )

    events: list[tuple[str, dict]] = []

    def on_event(name: str, data: dict) -> None:
        events.append((name, data))

    target = _make_anthropic_target()
    adapter = AnthropicAdapter(
        target=target,
        settings=get_settings(),
        user_settings={},
        system_prompt="planning system",
        conversation=[],
        user_text="add salmon to wednesday",
    )
    result = _run_provider_tool_loop(
        adapter=adapter,
        target=target,
        settings=get_settings(),
        tool_runner=tool_runner,
        on_event=on_event,
        abort_event=None,
    )

    assert invocations == [("add_meal", {"day_name": "Wed"})]
    event_names = [name for name, _ in events]
    assert "assistant.tool_call" in event_names
    assert "assistant.tool_result" in event_names
    assert "week.updated" in event_names

    # Tool transcript carried back on the AssistantTurnResult mirrors OpenAI's
    # shape so downstream persistence + iOS rendering are provider-agnostic.
    assert len(result.tool_calls) == 1
    assert result.tool_calls[0]["name"] == "add_meal"
    assert result.tool_calls[0]["ok"] is True
    assert result.envelope.assistant_markdown == "Done."


def test_anthropic_tool_result_loops_back_into_next_turn(monkeypatch) -> None:
    """After a tool runs, the second request must include the assistant's
    `tool_use` block AND the `tool_result` content block so Anthropic can
    continue the conversation."""
    streams = [
        _build_anthropic_stream_lines(
            tool_calls=[
                {
                    "id": "toolu_get_1",
                    "name": "get_current_week",
                    "input": {},
                }
            ],
            stop_reason="tool_use",
        ),
        _build_anthropic_stream_lines(
            text_chunks=["Here is your week."], stop_reason="end_turn"
        ),
    ]
    fake_client = _FakeAnthropicClient(streams)
    monkeypatch.setattr(
        "app.services.assistant_ai.httpx.Client",
        lambda *args, **kwargs: fake_client,  # noqa: ARG005
    )
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key",
        lambda *a, **k: "sk-ant-fake",  # noqa: ARG005
    )

    def tool_runner(name: str, args: dict[str, object]) -> AssistantToolResult:  # noqa: ARG001
        return AssistantToolResult(ok=True, detail="ok", week={"week_id": "w1"})

    target = _make_anthropic_target()
    adapter = AnthropicAdapter(
        target=target,
        settings=get_settings(),
        user_settings={},
        system_prompt="planning system",
        conversation=[],
        user_text="show my week",
    )
    _run_provider_tool_loop(
        adapter=adapter,
        target=target,
        settings=get_settings(),
        tool_runner=tool_runner,
        on_event=None,
        abort_event=None,
    )

    assert len(fake_client.requests) == 2
    second_body = fake_client.requests[1].json
    messages = second_body["messages"]
    # The original user turn is the first message; the assistant tool_use
    # block + a user-role message containing tool_result follow.
    roles = [m["role"] for m in messages]
    assert roles == ["user", "assistant", "user"]

    # Assistant message carries the tool_use block.
    tool_use_blocks = [
        block for block in messages[1]["content"] if block["type"] == "tool_use"
    ]
    assert len(tool_use_blocks) == 1
    assert tool_use_blocks[0]["id"] == "toolu_get_1"
    assert tool_use_blocks[0]["name"] == "get_current_week"

    # Tool-result message wraps the runner output keyed by tool_use_id.
    tool_result_blocks = [
        block for block in messages[2]["content"] if block["type"] == "tool_result"
    ]
    assert len(tool_result_blocks) == 1
    assert tool_result_blocks[0]["tool_use_id"] == "toolu_get_1"

    # Second request still carries the system prompt + tools schema.
    assert second_body["system"] == "planning system"
    assert "tools" in second_body and len(second_body["tools"]) > 0
    # Anthropic uses input_schema, not the OpenAI nested shape.
    assert "input_schema" in second_body["tools"][0]


def test_anthropic_text_only_turn_emits_deltas(monkeypatch) -> None:
    """A non-tool Anthropic turn streams `assistant.delta` events at the
    same cadence as the OpenAI loop. No tool runner is consulted; no
    `assistant.tool_call` event fires."""
    streams = [
        _build_anthropic_stream_lines(
            text_chunks=["Hello", ", ", "Daisy."], stop_reason="end_turn"
        )
    ]
    fake_client = _FakeAnthropicClient(streams)
    monkeypatch.setattr(
        "app.services.assistant_ai.httpx.Client",
        lambda *args, **kwargs: fake_client,  # noqa: ARG005
    )
    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_direct_api_key",
        lambda *a, **k: "sk-ant-fake",  # noqa: ARG005
    )

    def never_called(name: str, args: dict[str, object]) -> AssistantToolResult:  # noqa: ARG001
        raise AssertionError("tool_runner must not fire on a text-only turn")

    events: list[tuple[str, dict]] = []

    def on_event(name: str, data: dict) -> None:
        events.append((name, data))

    target = _make_anthropic_target()
    adapter = AnthropicAdapter(
        target=target,
        settings=get_settings(),
        user_settings={},
        system_prompt="planning system",
        conversation=[],
        user_text="hi",
    )
    result = _run_provider_tool_loop(
        adapter=adapter,
        target=target,
        settings=get_settings(),
        tool_runner=never_called,
        on_event=on_event,
        abort_event=None,
    )

    delta_events = [data["delta"] for name, data in events if name == "assistant.delta"]
    assert delta_events == ["Hello", ", ", "Daisy."]
    assert "assistant.tool_call" not in [name for name, _ in events]
    assert result.envelope.assistant_markdown == "Hello, Daisy."
    assert result.cancelled is False


def test_dispatch_routes_anthropic_planning_to_tool_loop(monkeypatch) -> None:
    """`run_assistant_turn` should route a tool-enabled, Anthropic-direct
    target through `_run_provider_tool_loop` (not the envelope path).
    Verifies the dispatch table change at line 162-179 actually picks up
    Anthropic now that an adapter is registered.
    """
    captured: dict[str, object] = {}

    def fake_loop(*, adapter, target, **_kwargs):
        captured["adapter_class"] = type(adapter).__name__
        captured["provider_name"] = target.provider_name
        from app.services.assistant_ai import (
            AssistantProviderEnvelope,
            AssistantTurnResult,
        )

        return AssistantTurnResult(
            target=target,
            prompt="system",
            raw_output="{}",
            envelope=AssistantProviderEnvelope(assistant_markdown="ok"),
            provider_thread_id=None,
            tool_calls=[],
            streamed_deltas=True,
        )

    monkeypatch.setattr(
        "app.services.assistant_ai._run_provider_tool_loop", fake_loop
    )

    def fake_resolve(settings, user_settings, *, existing_provider_thread_id=None):  # noqa: ARG001
        return _make_anthropic_target()

    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_assistant_execution_target", fake_resolve
    )

    def tool_runner(name: str, args: dict) -> AssistantToolResult:  # noqa: ARG001
        return AssistantToolResult(ok=True, detail="")

    run_assistant_turn(
        settings=get_settings(),
        user_settings={},
        thread_title="T",
        conversation=[],
        request=AssistantRespondRequest(text="plan", intent="planning"),
        tool_runner=tool_runner,
    )

    assert captured["adapter_class"] == "AnthropicAdapter"
    assert captured["provider_name"] == "anthropic"


def test_dispatch_still_routes_openai_planning_to_tool_loop(monkeypatch) -> None:
    """Regression guard: the same dispatch must keep routing OpenAI."""
    captured: dict[str, object] = {}

    def fake_loop(*, adapter, target, **_kwargs):
        captured["adapter_class"] = type(adapter).__name__
        from app.services.assistant_ai import (
            AssistantProviderEnvelope,
            AssistantTurnResult,
        )

        return AssistantTurnResult(
            target=target,
            prompt="system",
            raw_output="{}",
            envelope=AssistantProviderEnvelope(assistant_markdown="ok"),
            provider_thread_id=None,
            tool_calls=[],
            streamed_deltas=True,
        )

    monkeypatch.setattr(
        "app.services.assistant_ai._run_provider_tool_loop", fake_loop
    )

    target = AssistantExecutionTarget(
        provider_kind="direct",
        source="test",
        provider_name="openai",
        model="test-model",
    )

    def fake_resolve(settings, user_settings, *, existing_provider_thread_id=None):  # noqa: ARG001
        return target

    monkeypatch.setattr(
        "app.services.assistant_ai.resolve_assistant_execution_target", fake_resolve
    )

    def tool_runner(name: str, args: dict) -> AssistantToolResult:  # noqa: ARG001
        return AssistantToolResult(ok=True, detail="")

    run_assistant_turn(
        settings=get_settings(),
        user_settings={},
        thread_title="T",
        conversation=[],
        request=AssistantRespondRequest(text="plan", intent="planning"),
        tool_runner=tool_runner,
    )

    assert captured["adapter_class"] == "OpenAIAdapter"


# Sanity check that pytest collects this file's helper imports without
# accidentally pulling unused symbols.
def test_imports() -> None:
    assert OpenAIAdapter is not None
    assert AnthropicAdapter is not None
    assert _run_provider_tool_loop is not None
    # AssistantToolResult import is exercised by the runner closures above.
    pytest.importorskip("httpx")
