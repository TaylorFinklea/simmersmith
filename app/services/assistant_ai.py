from __future__ import annotations

import asyncio
import json
import logging
import threading
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Literal

import httpx
from fastapi.encoders import jsonable_encoder
from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.schemas import AssistantRespondRequest, RecipePayload
from app.services.ai import SUPPORTED_DIRECT_PROVIDERS, direct_provider_availability, resolve_direct_api_key, resolve_direct_model
from app.services.provider_models import openai_chat_body
from app.services.assistant_tools import (
    MAX_TOOL_ITERATIONS,
    AssistantToolResult,
    anthropic_tools_schema,
    openai_tools_schema,
)
from app.services.mcp_client import run_codex_mcp

logger = logging.getLogger(__name__)

ToolRunner = Callable[[str, dict], AssistantToolResult]
EventCallback = Callable[[str, dict], None]


@dataclass(frozen=True)
class StreamToolCall:
    """A complete tool call surfaced by a provider's streaming parser.

    `id` is provider-assigned (OpenAI's `call_*` or Anthropic's `toolu_*`).
    `args` is the parsed JSON arguments object.
    """
    id: str
    name: str
    args: dict[str, object]


@dataclass(frozen=True)
class ToolResultPayload:
    """A tool result fed back into the next turn's request body."""
    call_id: str
    result: AssistantToolResult


@dataclass
class NormalizedStreamEvent:
    """Provider-agnostic stream event yielded by `ProviderAdapter.parse_stream_line`.

    `kind`:
      - `text_delta`: incremental assistant text. `text` is the chunk.
      - `tool_call_complete`: a tool call's arguments are fully accumulated.
        `tool_call` is the parsed call. The loop runs the tool and feeds
        the result back via `record_tool_results`.
      - `turn_done`: the model finished this turn. `is_terminal` is True
        when the turn ended without pending tool calls (OpenAI `stop`,
        Anthropic `end_turn`); False when the model paused for tool use
        (OpenAI `tool_calls`, Anthropic `tool_use`).
    """
    kind: Literal["text_delta", "tool_call_complete", "turn_done"]
    text: str = ""
    tool_call: StreamToolCall | None = None
    is_terminal: bool = False


class AssistantProviderEnvelope(BaseModel):
    assistant_markdown: str
    recipe_draft: RecipePayload | None = None


def strict_json_schema(model: type[BaseModel]) -> dict[str, object]:
    schema = model.model_json_schema()
    _apply_strict_object_schema(schema)
    return schema


def _apply_strict_object_schema(node: object) -> None:
    if isinstance(node, dict):
        node_type = node.get("type")
        if node_type == "object":
            node["additionalProperties"] = False
            properties = node.get("properties")
            if isinstance(properties, dict):
                node["required"] = list(properties.keys())
        for value in node.values():
            _apply_strict_object_schema(value)
    elif isinstance(node, list):
        for item in node:
            _apply_strict_object_schema(item)


@dataclass(frozen=True)
class AssistantExecutionTarget:
    provider_kind: str
    source: str
    model: str
    provider_name: str | None = None
    mcp_server_name: str | None = None

    def as_payload(self) -> dict[str, object]:
        return {
            "provider_kind": self.provider_kind,
            "source": self.source,
            "model": self.model,
            "provider_name": self.provider_name,
            "mcp_server_name": self.mcp_server_name,
        }


@dataclass(frozen=True)
class AssistantTurnResult:
    target: AssistantExecutionTarget
    prompt: str
    raw_output: str
    envelope: AssistantProviderEnvelope
    provider_thread_id: str | None = None
    tool_calls: list[dict[str, object]] = field(default_factory=list)
    # True when the runner already emitted `assistant.delta` events via the
    # on_event callback (streaming mode). When True the endpoint should skip
    # re-emitting the final content as chunks.
    streamed_deltas: bool = False
    # True when the turn exited early because the caller's `abort_event`
    # fired (typically client disconnect). The envelope still carries any
    # text that arrived before the abort.
    cancelled: bool = False


def resolve_assistant_execution_target(
    settings: Settings,
    user_settings: dict[str, str],
    *,
    existing_provider_thread_id: str | None = None,
) -> AssistantExecutionTarget:
    if existing_provider_thread_id:
        if settings.ai_mcp_enabled and settings.ai_mcp_base_url.strip():
            return AssistantExecutionTarget(
                provider_kind="mcp",
                source="server",
                provider_name=settings.ai_mcp_server_name,
                model=settings.ai_mcp_server_name,
                mcp_server_name=settings.ai_mcp_server_name,
            )
        raise RuntimeError("This assistant thread requires MCP, but MCP is not configured on the server.")

    preferred_direct = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    direct_candidates = []
    if preferred_direct in SUPPORTED_DIRECT_PROVIDERS:
        direct_candidates.append(preferred_direct)
    for provider_name in SUPPORTED_DIRECT_PROVIDERS:
        if provider_name not in direct_candidates:
            direct_candidates.append(provider_name)

    for provider_name in direct_candidates:
        available, source = direct_provider_availability(provider_name, settings=settings, user_settings=user_settings)
        if not available:
            continue
        model = resolve_direct_model(provider_name, settings=settings, user_settings=user_settings)
        return AssistantExecutionTarget(
            provider_kind="direct",
            source=source,
            provider_name=provider_name,
            model=model,
        )

    if settings.ai_mcp_enabled and settings.ai_mcp_base_url.strip():
        return AssistantExecutionTarget(
            provider_kind="mcp",
            source="server",
            provider_name=settings.ai_mcp_server_name,
            model=settings.ai_mcp_server_name,
            mcp_server_name=settings.ai_mcp_server_name,
        )
    raise RuntimeError("No direct AI provider is configured and MCP is unavailable.")


def run_assistant_turn(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None = None,
    existing_provider_thread_id: str | None = None,
    tool_runner: ToolRunner | None = None,
    on_event: EventCallback | None = None,
    planning_context: str | None = None,
    abort_event: threading.Event | None = None,
) -> AssistantTurnResult:
    target = resolve_assistant_execution_target(
        settings,
        user_settings,
        existing_provider_thread_id=existing_provider_thread_id,
    )

    if (
        tool_runner is not None
        and target.provider_kind == "direct"
        and target.provider_name in _PROVIDER_ADAPTERS
    ):
        adapter_factory = _PROVIDER_ADAPTERS[target.provider_name]
        system_prompt = build_planning_system_prompt(
            thread_title=thread_title,
            planning_context=planning_context or "",
            user_settings=user_settings,
        )
        attached_note = ""
        if attached_recipe is not None:
            attached_note = (
                "\nAttached recipe context:\n"
                f"{json.dumps(attached_recipe.model_dump(mode='json'), indent=2)}\n"
            )
        user_text = (request.text.strip() or "(empty message)") + attached_note
        adapter = adapter_factory(
            target=target,
            settings=settings,
            user_settings=user_settings,
            system_prompt=system_prompt,
            conversation=conversation,
            user_text=user_text,
        )
        return _run_provider_tool_loop(
            adapter=adapter,
            target=target,
            settings=settings,
            tool_runner=tool_runner,
            on_event=on_event,
            abort_event=abort_event,
        )

    prompt = build_assistant_prompt(
        thread_title=thread_title,
        conversation=conversation,
        request=request,
        attached_recipe=attached_recipe,
        planning_context=planning_context,
        user_settings=user_settings,
    )
    provider_thread_id = existing_provider_thread_id
    if target.provider_kind == "mcp":
        mcp_result = asyncio.run(
            run_codex_mcp(
                settings=settings,
                prompt=prompt,
                thread_id=existing_provider_thread_id,
            )
        )
        raw_output = mcp_result.text
        provider_thread_id = mcp_result.thread_id
    else:
        raw_output = run_direct_provider(target=target, settings=settings, user_settings=user_settings, prompt=prompt)
    envelope = parse_provider_envelope(raw_output)
    return AssistantTurnResult(
        target=target,
        prompt=prompt,
        raw_output=raw_output,
        envelope=envelope,
        provider_thread_id=provider_thread_id,
    )


class ProviderAdapter(ABC):
    """Per-turn glue around the provider-agnostic tool loop.

    One instance per assistant turn. Owns the `messages` list and any
    per-stream accumulator state (e.g. partial tool-call arg JSON). The
    outer loop calls these in order:

      1. `request_url()`, `request_headers()`, `request_body()` to build
         the streaming POST.
      2. `parse_stream_line(line)` for each SSE line received. The adapter
         updates internal accumulators and yields normalized events.
      3. `record_assistant_turn(turn_text, tool_calls)` once a turn closes,
         to push the assistant's response onto the messages history.
      4. `record_tool_results(results)` after tools run, to push tool
         results onto the messages history for the next request.
    """

    def __init__(
        self,
        *,
        target: AssistantExecutionTarget,
        settings: Settings,
        user_settings: dict[str, str],
        system_prompt: str,
        conversation: list[dict[str, object]],
        user_text: str,
    ) -> None:
        self.target = target
        self.settings = settings
        self.user_settings = user_settings
        self.system_prompt = system_prompt
        self.messages: list[dict[str, object]] = []
        self._init_messages(conversation, user_text)

    @abstractmethod
    def _init_messages(self, conversation: list[dict[str, object]], user_text: str) -> None:
        """Seed `self.messages` with prior conversation + the new user turn."""

    @abstractmethod
    def request_url(self) -> str: ...

    @abstractmethod
    def request_headers(self) -> dict[str, str]: ...

    @abstractmethod
    def request_body(self) -> dict[str, object]: ...

    @abstractmethod
    def reset_stream_state(self) -> None:
        """Clear any per-stream accumulators before a new POST."""

    @abstractmethod
    def parse_stream_line(self, line: str) -> list[NormalizedStreamEvent]:
        """Translate one SSE line into 0+ normalized events."""

    @abstractmethod
    def record_assistant_turn(
        self, turn_text: str, tool_calls: list[StreamToolCall]
    ) -> None:
        """Append the just-finished assistant turn to `self.messages`."""

    @abstractmethod
    def record_tool_results(self, results: list[ToolResultPayload]) -> None:
        """Append tool results to `self.messages` for the next request."""


class OpenAIAdapter(ProviderAdapter):
    """OpenAI Chat Completions API tool-use over SSE.

    Streams `choices[0].delta.content` text chunks and incremental
    `delta.tool_calls[i].function.arguments` JSON fragments. Tool calls
    are emitted as `tool_call_complete` events when the chunk's
    `finish_reason` arrives — at that point the accumulated arguments
    are parsed.
    """

    def _init_messages(self, conversation: list[dict[str, object]], user_text: str) -> None:
        self.messages.append({"role": "system", "content": self.system_prompt})
        for message in conversation[-20:]:
            role = str(message.get("role", "user"))
            content = str(message.get("content_markdown", "")).strip()
            if not content:
                continue
            self.messages.append(
                {"role": "assistant" if role == "assistant" else "user", "content": content}
            )
        self.messages.append({"role": "user", "content": user_text})
        self._tool_calls_acc: dict[int, dict[str, str]] = {}

    def request_url(self) -> str:
        return "https://api.openai.com/v1/chat/completions"

    def request_headers(self) -> dict[str, str]:
        api_key = resolve_direct_api_key(
            "openai", settings=self.settings, user_settings=self.user_settings
        )
        return {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def request_body(self) -> dict[str, object]:
        return openai_chat_body(
            model=self.target.model,
            base={
                "messages": self.messages,
                "tools": openai_tools_schema(),
                "tool_choice": "auto",
                "temperature": 0.3,
                "stream": True,
            },
        )

    def reset_stream_state(self) -> None:
        self._tool_calls_acc = {}

    def parse_stream_line(self, line: str) -> list[NormalizedStreamEvent]:
        if not line or not line.startswith("data: "):
            return []
        data_str = line[6:]
        if data_str == "[DONE]":
            # OpenAI's terminal sentinel — emit a non-terminal turn_done so
            # the loop falls through to the post-stream tool-call check.
            # Whether the turn is *actually* terminal depends on whether any
            # tool calls accumulated; the loop decides.
            return []
        try:
            chunk = json.loads(data_str)
        except json.JSONDecodeError:
            return []
        choices = chunk.get("choices") or []
        if not choices:
            return []
        choice = choices[0]
        delta = choice.get("delta") or {}
        events: list[NormalizedStreamEvent] = []
        content_piece = delta.get("content")
        if content_piece:
            events.append(NormalizedStreamEvent(kind="text_delta", text=content_piece))
        for tc_delta in delta.get("tool_calls") or []:
            idx = tc_delta.get("index")
            if idx is None:
                continue
            acc = self._tool_calls_acc.setdefault(
                int(idx), {"id": "", "name": "", "arguments": ""}
            )
            if tc_delta.get("id"):
                acc["id"] = str(tc_delta["id"])
            fn_delta = tc_delta.get("function") or {}
            if fn_delta.get("name"):
                acc["name"] += str(fn_delta["name"])
            if fn_delta.get("arguments"):
                acc["arguments"] += str(fn_delta["arguments"])
        finish_reason = choice.get("finish_reason")
        if finish_reason:
            # finish_reason="tool_calls" → tools to run; "stop" → terminal.
            for idx in sorted(self._tool_calls_acc.keys()):
                acc = self._tool_calls_acc[idx]
                call_id = acc["id"] or f"call_{idx}"
                name = acc["name"]
                raw_args = acc["arguments"] or "{}"
                try:
                    args = json.loads(raw_args)
                    if not isinstance(args, dict):
                        args = {}
                except json.JSONDecodeError:
                    args = {}
                events.append(
                    NormalizedStreamEvent(
                        kind="tool_call_complete",
                        tool_call=StreamToolCall(id=call_id, name=name, args=args),
                    )
                )
            events.append(
                NormalizedStreamEvent(
                    kind="turn_done",
                    is_terminal=(str(finish_reason) == "stop"),
                )
            )
        return events

    def record_assistant_turn(
        self, turn_text: str, tool_calls: list[StreamToolCall]
    ) -> None:
        if not tool_calls:
            return
        # Preserve OpenAI's expected assistant message shape for the next turn.
        assistant_msg_tool_calls = [
            {
                "id": call.id,
                "type": "function",
                "function": {
                    "name": call.name,
                    "arguments": json.dumps(call.args),
                },
            }
            for call in tool_calls
        ]
        self.messages.append(
            {
                "role": "assistant",
                "content": turn_text or None,
                "tool_calls": assistant_msg_tool_calls,
            }
        )

    def record_tool_results(self, results: list[ToolResultPayload]) -> None:
        for payload in results:
            self.messages.append(
                {
                    "role": "tool",
                    "tool_call_id": payload.call_id,
                    # `result.to_model_reply()` can contain `date` / `datetime`
                    # objects (week_start, meal_date) from the week payload.
                    # Plain `json.dumps` can't serialize those — route through
                    # FastAPI's jsonable_encoder first.
                    "content": json.dumps(jsonable_encoder(payload.result.to_model_reply())),
                }
            )


class AnthropicAdapter(ProviderAdapter):
    """Anthropic Messages API tool-use over SSE.

    Anthropic streams events of distinct types (`message_start`,
    `content_block_start`, `content_block_delta`, `content_block_stop`,
    `message_delta`, `message_stop`). Tool calls arrive as `tool_use`
    content blocks whose JSON arguments stream incrementally via
    `input_json_delta` events; the adapter accumulates `input_json_acc`
    per block and emits `tool_call_complete` on `content_block_stop`.
    Turn termination arrives via `message_delta` with a `stop_reason`
    of `end_turn` (terminal) or `tool_use` (tools pending).
    """

    def _init_messages(self, conversation: list[dict[str, object]], user_text: str) -> None:
        # Anthropic carries the system prompt as a top-level request field,
        # not as a message in the array. Skip seeding it into messages.
        for message in conversation[-20:]:
            role = str(message.get("role", "user"))
            content = str(message.get("content_markdown", "")).strip()
            if not content:
                continue
            self.messages.append(
                {"role": "assistant" if role == "assistant" else "user", "content": content}
            )
        self.messages.append({"role": "user", "content": user_text})
        self._active_blocks: dict[int, dict[str, object]] = {}
        self._pending_event: str | None = None
        self._pending_data_lines: list[str] = []

    def request_url(self) -> str:
        return "https://api.anthropic.com/v1/messages"

    def request_headers(self) -> dict[str, str]:
        api_key = resolve_direct_api_key(
            "anthropic", settings=self.settings, user_settings=self.user_settings
        )
        return {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }

    def request_body(self) -> dict[str, object]:
        return {
            "model": self.target.model,
            "max_tokens": 1800,
            "system": self.system_prompt,
            "messages": self.messages,
            "tools": anthropic_tools_schema(),
            "stream": True,
        }

    def reset_stream_state(self) -> None:
        self._active_blocks = {}
        self._pending_event = None
        self._pending_data_lines = []

    def parse_stream_line(self, line: str) -> list[NormalizedStreamEvent]:
        # Anthropic SSE: alternating `event: <name>` and `data: <json>` lines
        # separated by blank lines. Accumulate until we have an event+data
        # pair, then dispatch.
        if line == "":
            return self._dispatch_pending_event()
        if line.startswith("event: "):
            self._pending_event = line[7:].strip()
            return []
        if line.startswith("data: "):
            self._pending_data_lines.append(line[6:])
            return []
        return []

    def _dispatch_pending_event(self) -> list[NormalizedStreamEvent]:
        event_name = self._pending_event
        data_lines = self._pending_data_lines
        self._pending_event = None
        self._pending_data_lines = []
        if event_name is None or not data_lines:
            return []
        data_str = "".join(data_lines)
        try:
            data = json.loads(data_str)
        except json.JSONDecodeError:
            return []

        if event_name == "content_block_start":
            block = data.get("content_block") or {}
            index = data.get("index")
            if isinstance(index, int) and isinstance(block, dict):
                if block.get("type") == "tool_use":
                    self._active_blocks[index] = {
                        "type": "tool_use",
                        "id": str(block.get("id") or ""),
                        "name": str(block.get("name") or ""),
                        "input_json_acc": "",
                    }
                elif block.get("type") == "text":
                    self._active_blocks[index] = {"type": "text"}
            return []

        if event_name == "content_block_delta":
            delta = data.get("delta") or {}
            delta_type = delta.get("type")
            index = data.get("index")
            if delta_type == "text_delta":
                text = str(delta.get("text") or "")
                if text:
                    return [NormalizedStreamEvent(kind="text_delta", text=text)]
            elif delta_type == "input_json_delta" and isinstance(index, int):
                block = self._active_blocks.get(index)
                if block is not None and block.get("type") == "tool_use":
                    block["input_json_acc"] = (
                        str(block.get("input_json_acc") or "")
                        + str(delta.get("partial_json") or "")
                    )
            return []

        if event_name == "content_block_stop":
            index = data.get("index")
            if not isinstance(index, int):
                return []
            block = self._active_blocks.pop(index, None)
            if block is None or block.get("type") != "tool_use":
                return []
            raw_args = str(block.get("input_json_acc") or "")
            if not raw_args.strip():
                args: dict[str, object] = {}
            else:
                try:
                    parsed = json.loads(raw_args)
                    args = parsed if isinstance(parsed, dict) else {}
                except json.JSONDecodeError:
                    args = {}
            return [
                NormalizedStreamEvent(
                    kind="tool_call_complete",
                    tool_call=StreamToolCall(
                        id=str(block.get("id") or f"toolu_{index}"),
                        name=str(block.get("name") or ""),
                        args=args,
                    ),
                )
            ]

        if event_name == "message_delta":
            delta = data.get("delta") or {}
            stop_reason = str(delta.get("stop_reason") or "")
            if stop_reason:
                return [
                    NormalizedStreamEvent(
                        kind="turn_done",
                        is_terminal=(stop_reason == "end_turn"),
                    )
                ]
            return []

        # message_start, message_stop, ping → no normalized event
        return []

    def record_assistant_turn(
        self, turn_text: str, tool_calls: list[StreamToolCall]
    ) -> None:
        if not tool_calls and not turn_text:
            return
        content: list[dict[str, object]] = []
        if turn_text:
            content.append({"type": "text", "text": turn_text})
        for call in tool_calls:
            content.append(
                {
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": call.args,
                }
            )
        self.messages.append({"role": "assistant", "content": content})

    def record_tool_results(self, results: list[ToolResultPayload]) -> None:
        if not results:
            return
        # Anthropic packs all tool results into a single user-role message.
        self.messages.append(
            {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": payload.call_id,
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    jsonable_encoder(payload.result.to_model_reply())
                                ),
                            }
                        ],
                    }
                    for payload in results
                ],
            }
        )


_PROVIDER_ADAPTERS: dict[str, type[ProviderAdapter]] = {
    "openai": OpenAIAdapter,
    "anthropic": AnthropicAdapter,
}


def _run_provider_tool_loop(
    *,
    adapter: ProviderAdapter,
    target: AssistantExecutionTarget,
    settings: Settings,
    tool_runner: ToolRunner,
    on_event: EventCallback | None,
    abort_event: threading.Event | None = None,
) -> AssistantTurnResult:
    tool_transcript: list[dict[str, object]] = []
    final_text: str | None = None
    raw_final = ""
    accumulated_text = ""
    cancelled = False

    def _emit(event: str, payload: dict[str, object]) -> None:
        if on_event is not None:
            try:
                on_event(event, payload)
            except Exception:
                logger.exception("Assistant event callback raised")

    def _is_aborted() -> bool:
        return abort_event is not None and abort_event.is_set()

    for iteration in range(MAX_TOOL_ITERATIONS):
        if _is_aborted():
            cancelled = True
            break
        adapter.reset_stream_state()
        # Per-turn state captured into the loop body so abort+cleanup work.
        turn_text = ""
        completed_calls: list[StreamToolCall] = []
        terminal = False

        with httpx.Client(timeout=settings.ai_timeout_seconds) as client:
            with client.stream(
                "POST",
                adapter.request_url(),
                headers=adapter.request_headers(),
                json=adapter.request_body(),
            ) as response:
                response.raise_for_status()
                for line in response.iter_lines():
                    if _is_aborted():
                        cancelled = True
                        break
                    for ev in adapter.parse_stream_line(line):
                        if ev.kind == "text_delta":
                            turn_text += ev.text
                            accumulated_text += ev.text
                            _emit("assistant.delta", {"delta": ev.text})
                        elif ev.kind == "tool_call_complete" and ev.tool_call is not None:
                            completed_calls.append(ev.tool_call)
                        elif ev.kind == "turn_done":
                            terminal = ev.is_terminal
        if cancelled:
            break

        # Capture the last raw chunk for AIRun logging (full record is
        # approximated as the accumulated text + tool calls).
        raw_final = json.dumps(
            {
                "terminal": terminal,
                "content": turn_text,
                "tool_calls": [
                    {"id": c.id, "name": c.name, "arguments": c.args}
                    for c in completed_calls
                ],
            }
        )

        if not completed_calls:
            final_text = turn_text.strip()
            break

        adapter.record_assistant_turn(turn_text, completed_calls)

        tool_results: list[ToolResultPayload] = []
        for call in completed_calls:
            if _is_aborted():
                cancelled = True
                break
            call_id = call.id or str(uuid.uuid4())
            started_at = datetime.now(timezone.utc).isoformat()
            _emit(
                "assistant.tool_call",
                {
                    "call_id": call_id,
                    "name": call.name,
                    "arguments": call.args,
                    "status": "running",
                    "started_at": started_at,
                },
            )

            result = tool_runner(call.name, call.args)

            completed_at = datetime.now(timezone.utc).isoformat()
            tool_entry: dict[str, object] = {
                "call_id": call_id,
                "name": call.name,
                "arguments": call.args,
                "ok": result.ok,
                "detail": result.detail,
                "status": "completed" if result.ok else "failed",
                "started_at": started_at,
                "completed_at": completed_at,
            }
            # M26 Phase 5: surface tool `data` (e.g. proposed_change for
            # the dry-run confirm flow) so the iOS client can render the
            # diff card. Only include when non-empty to keep the
            # transcript compact for tools that don't carry payloads.
            if result.data:
                tool_entry["data"] = result.data
            tool_transcript.append(tool_entry)

            _emit("assistant.tool_result", dict(tool_entry))
            if result.week is not None:
                _emit("week.updated", {"week": result.week})

            tool_results.append(ToolResultPayload(call_id=call_id, result=result))

        if cancelled:
            break
        adapter.record_tool_results(tool_results)
        if terminal:
            final_text = turn_text.strip()
            break
    else:
        logger.warning("Assistant tool loop exceeded %s iterations", MAX_TOOL_ITERATIONS)

    if cancelled:
        # Preserve whatever arrived before the abort so the persisted
        # message and audit log show partial progress.
        final_text = accumulated_text.strip()
    if final_text is None or not final_text:
        final_text = accumulated_text.strip() or (
            "Turn cancelled." if cancelled
            else "I hit a tool-call limit before I could finish. Can you try again?"
        )

    envelope = AssistantProviderEnvelope(
        assistant_markdown=final_text or ("Cancelled." if cancelled else "Done.")
    )
    return AssistantTurnResult(
        target=target,
        prompt=adapter.system_prompt,
        raw_output=raw_final,
        envelope=envelope,
        provider_thread_id=None,
        tool_calls=tool_transcript,
        streamed_deltas=True,
        cancelled=cancelled,
    )


def build_planning_system_prompt(
    *, thread_title: str, planning_context: str, user_settings: dict[str, str] | None = None
) -> str:
    from app.services.ai import unit_system_directive

    units_directive = unit_system_directive(user_settings or {})
    return (
        "You are SimmerSmith's Planning Assistant, a conversational agent that helps "
        "a single user plan their week of meals.\n"
        f"{units_directive}\n"
        "You have tools that can READ and MODIFY the user's current week in real time. "
        "When the user asks for a change, CALL THE TOOL rather than describing what you would do. "
        "Do not claim to have done something you haven't called a tool for.\n"
        "When a tool returns ok=false, tell the user the tool's detail verbatim and propose a recovery.\n"
        "After you call tools, end your turn with a short, natural-language summary of what changed. "
        "Do NOT wrap your final reply in JSON or markdown fences.\n"
        "Prefer small edits (add/swap/remove/rebalance) to a full regenerate — only call generate_week_plan "
        "when the user asks for a full reset.\n"
        "Be concise. Two or three sentences per reply is plenty.\n\n"
        f"Thread: {thread_title or 'Weekly Planning'}\n"
        f"{planning_context}"
    )


def build_assistant_prompt(
    *,
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None,
    planning_context: str | None = None,
    user_settings: dict[str, str] | None = None,
) -> str:
    from app.services.ai import unit_system_directive
    units_directive = unit_system_directive(user_settings or {})
    envelope_schema = json.dumps(strict_json_schema(AssistantProviderEnvelope), indent=2)
    transcript = []
    for message in conversation[-10:]:
        role = str(message.get("role", "user")).upper()
        content = str(message.get("content_markdown", "")).strip()
        transcript.append(f"{role}: {content}")
        recipe_draft = message.get("recipe_draft")
        if recipe_draft:
            transcript.append(f"{role}_RECIPE_DRAFT:\n{json.dumps(recipe_draft, indent=2)}")

    attached_context = ""
    if attached_recipe is not None:
        attached_context = f"\nAttached recipe context:\n{json.dumps(attached_recipe.model_dump(mode='json'), indent=2)}\n"

    return (
        "You are SimmerSmith Assistant, an in-app cooking and recipe assistant.\n"
        f"{units_directive}\n"
        "You must respond with exactly one JSON object that matches the provided schema.\n"
        "Never wrap the JSON in markdown fences.\n"
        "Never include any text outside the JSON object.\n"
        "Never claim to have saved or published anything.\n"
        "You may optionally include one recipe_draft when the user asks for recipe creation or recipe refinement.\n"
        "If you include a recipe_draft, it must be complete enough to open in an editor.\n"
        "assistant_markdown must never be empty. If you include a recipe_draft, assistant_markdown must briefly summarize the proposed recipe.\n"
        "For cooking help, recipe_draft should usually be null.\n\n"
        f"Response schema:\n{envelope_schema}\n\n"
        f"Thread title: {thread_title or 'New Assistant Chat'}\n"
        f"Intent: {request.intent}\n"
        f"{attached_context}"
        "Recent conversation:\n"
        f"{chr(10).join(transcript) if transcript else '(no previous messages)'}\n\n"
        "Current user message:\n"
        f"{request.text.strip() or '(empty message)'}\n"
    )


def run_direct_provider(
    *,
    target: AssistantExecutionTarget,
    settings: Settings,
    user_settings: dict[str, str],
    prompt: str,
) -> str:
    headers = {"Content-Type": "application/json"}
    timeout = settings.ai_timeout_seconds
    if target.provider_name == "openai":
        headers["Authorization"] = f"Bearer {resolve_direct_api_key('openai', settings=settings, user_settings=user_settings)}"
        body = openai_chat_body(
            model=target.model,
            base={
                "messages": [
                    {"role": "system", "content": "Return only valid JSON matching the requested schema."},
                    {"role": "user", "content": prompt},
                ],
                "temperature": 0.4,
            },
        )
        with httpx.Client(timeout=timeout) as client:
            response = client.post("https://api.openai.com/v1/chat/completions", headers=headers, json=body)
        response.raise_for_status()
        payload = response.json()
        return str(payload["choices"][0]["message"]["content"])

    if target.provider_name == "anthropic":
        headers["x-api-key"] = resolve_direct_api_key("anthropic", settings=settings, user_settings=user_settings)
        headers["anthropic-version"] = "2023-06-01"
        body = {
            "model": target.model,
            "max_tokens": 1800,
            "system": "Return only valid JSON matching the requested schema.",
            "messages": [{"role": "user", "content": prompt}],
        }
        with httpx.Client(timeout=timeout) as client:
            response = client.post("https://api.anthropic.com/v1/messages", headers=headers, json=body)
        response.raise_for_status()
        payload = response.json()
        content = payload.get("content", [])
        text_chunks = [item.get("text", "") for item in content if item.get("type") == "text"]
        return "\n".join(chunk for chunk in text_chunks if chunk).strip()

    raise RuntimeError(f"Unsupported direct provider: {target.provider_name}")


def parse_provider_envelope(raw_output: str) -> AssistantProviderEnvelope:
    candidate = extract_json_object(raw_output)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI provider returned invalid JSON.") from exc
    try:
        envelope = AssistantProviderEnvelope.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI provider returned an unexpected payload shape.") from exc
    envelope.assistant_markdown = envelope.assistant_markdown.strip()
    if not envelope.assistant_markdown and envelope.recipe_draft is not None:
        envelope.assistant_markdown = "I put together a draft recipe for you to review below."
    if not envelope.assistant_markdown and envelope.recipe_draft is None:
        raise RuntimeError("AI provider returned an empty assistant response.")
    return envelope


def extract_json_object(raw_output: str) -> str:
    stripped = raw_output.strip()
    if stripped.startswith("{") and stripped.endswith("}"):
        return stripped
    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return stripped
    return stripped[start : end + 1]
