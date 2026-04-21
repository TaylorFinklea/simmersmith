from __future__ import annotations

import asyncio
import json
import logging
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable

import httpx
from fastapi.encoders import jsonable_encoder
from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.schemas import AssistantRespondRequest, RecipePayload
from app.services.ai import SUPPORTED_DIRECT_PROVIDERS, direct_provider_availability, resolve_direct_api_key, resolve_direct_model
from app.services.assistant_tools import (
    MAX_TOOL_ITERATIONS,
    AssistantToolResult,
    openai_tools_schema,
)
from app.services.mcp_client import run_codex_mcp

logger = logging.getLogger(__name__)

ToolRunner = Callable[[str, dict], AssistantToolResult]
EventCallback = Callable[[str, dict], None]


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
        and target.provider_name == "openai"
    ):
        return _run_openai_tool_loop(
            target=target,
            settings=settings,
            user_settings=user_settings,
            thread_title=thread_title,
            conversation=conversation,
            request=request,
            attached_recipe=attached_recipe,
            planning_context=planning_context or "",
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


def _run_openai_tool_loop(
    *,
    target: AssistantExecutionTarget,
    settings: Settings,
    user_settings: dict[str, str],
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None,
    planning_context: str,
    tool_runner: ToolRunner,
    on_event: EventCallback | None,
    abort_event: threading.Event | None = None,
) -> AssistantTurnResult:
    system_prompt = build_planning_system_prompt(
        thread_title=thread_title, planning_context=planning_context
    )
    attached_note = ""
    if attached_recipe is not None:
        attached_note = (
            "\nAttached recipe context:\n"
            f"{json.dumps(attached_recipe.model_dump(mode='json'), indent=2)}\n"
        )

    messages: list[dict[str, object]] = [{"role": "system", "content": system_prompt}]
    for message in conversation[-20:]:
        role = str(message.get("role", "user"))
        content = str(message.get("content_markdown", "")).strip()
        if not content:
            continue
        messages.append({"role": "assistant" if role == "assistant" else "user", "content": content})
    user_text = (request.text.strip() or "(empty message)") + attached_note
    messages.append({"role": "user", "content": user_text})

    tool_transcript: list[dict[str, object]] = []
    api_key = resolve_direct_api_key("openai", settings=settings, user_settings=user_settings)
    final_text: str | None = None
    raw_final = ""

    def _emit(event: str, payload: dict[str, object]) -> None:
        if on_event is not None:
            try:
                on_event(event, payload)
            except Exception:
                logger.exception("Assistant event callback raised")

    accumulated_text = ""
    cancelled = False

    def _is_aborted() -> bool:
        return abort_event is not None and abort_event.is_set()

    for iteration in range(MAX_TOOL_ITERATIONS):
        if _is_aborted():
            cancelled = True
            break
        # Stream tokens + tool_call deltas so the iOS client renders text as
        # it arrives instead of waiting for the whole response to buffer.
        turn_text = ""
        tool_calls_acc: dict[int, dict[str, str]] = {}
        finish_reason = ""

        with httpx.Client(timeout=settings.ai_timeout_seconds) as client:
            with client.stream(
                "POST",
                "https://api.openai.com/v1/chat/completions",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream",
                },
                json={
                    "model": target.model,
                    "messages": messages,
                    "tools": openai_tools_schema(),
                    "tool_choice": "auto",
                    "temperature": 0.3,
                    "stream": True,
                },
            ) as response:
                response.raise_for_status()
                for line in response.iter_lines():
                    if _is_aborted():
                        cancelled = True
                        break
                    if not line:
                        continue
                    if not line.startswith("data: "):
                        continue
                    data_str = line[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue
                    choices = chunk.get("choices") or []
                    if not choices:
                        continue
                    choice = choices[0]
                    delta = choice.get("delta") or {}
                    content_piece = delta.get("content")
                    if content_piece:
                        turn_text += content_piece
                        accumulated_text += content_piece
                        _emit("assistant.delta", {"delta": content_piece})
                    for tc_delta in delta.get("tool_calls") or []:
                        idx = tc_delta.get("index")
                        if idx is None:
                            continue
                        acc = tool_calls_acc.setdefault(
                            int(idx),
                            {"id": "", "name": "", "arguments": ""},
                        )
                        if tc_delta.get("id"):
                            acc["id"] = str(tc_delta["id"])
                        fn_delta = tc_delta.get("function") or {}
                        if fn_delta.get("name"):
                            acc["name"] += str(fn_delta["name"])
                        if fn_delta.get("arguments"):
                            acc["arguments"] += str(fn_delta["arguments"])
                    if choice.get("finish_reason"):
                        finish_reason = str(choice["finish_reason"])
        if cancelled:
            break

        # Capture the last raw chunk for AIRun logging (full record is
        # approximated as the accumulated text + tool calls).
        raw_final = json.dumps(
            {
                "finish_reason": finish_reason,
                "content": turn_text,
                "tool_calls": [
                    {
                        "index": idx,
                        "id": tc["id"],
                        "name": tc["name"],
                        "arguments": tc["arguments"],
                    }
                    for idx, tc in sorted(tool_calls_acc.items())
                ],
            }
        )

        if not tool_calls_acc:
            final_text = turn_text.strip()
            break

        # Preserve OpenAI's expected assistant message shape for the next turn.
        assistant_msg_tool_calls = [
            {
                "id": tool_calls_acc[idx]["id"] or f"call_{idx}",
                "type": "function",
                "function": {
                    "name": tool_calls_acc[idx]["name"],
                    "arguments": tool_calls_acc[idx]["arguments"] or "{}",
                },
            }
            for idx in sorted(tool_calls_acc.keys())
        ]
        messages.append(
            {
                "role": "assistant",
                "content": turn_text or None,
                "tool_calls": assistant_msg_tool_calls,
            }
        )

        for idx in sorted(tool_calls_acc.keys()):
            if _is_aborted():
                cancelled = True
                break
            acc = tool_calls_acc[idx]
            call_id = acc["id"] or str(uuid.uuid4())
            name = acc["name"]
            raw_args = acc["arguments"] or "{}"
            try:
                args = json.loads(raw_args)
                if not isinstance(args, dict):
                    args = {}
            except json.JSONDecodeError:
                args = {}

            started_at = datetime.now(timezone.utc).isoformat()
            _emit(
                "assistant.tool_call",
                {
                    "call_id": call_id,
                    "name": name,
                    "arguments": args,
                    "status": "running",
                    "started_at": started_at,
                },
            )

            result = tool_runner(name, args)

            completed_at = datetime.now(timezone.utc).isoformat()
            tool_entry: dict[str, object] = {
                "call_id": call_id,
                "name": name,
                "arguments": args,
                "ok": result.ok,
                "detail": result.detail,
                "status": "completed" if result.ok else "failed",
                "started_at": started_at,
                "completed_at": completed_at,
            }
            tool_transcript.append(tool_entry)

            _emit("assistant.tool_result", dict(tool_entry))
            if result.week is not None:
                _emit("week.updated", {"week": result.week})

            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call_id,
                    # `result.to_model_reply()` can contain `date` / `datetime`
                    # objects (week_start, meal_date) from the week payload.
                    # Plain `json.dumps` can't serialize those — route through
                    # FastAPI's jsonable_encoder first.
                    "content": json.dumps(jsonable_encoder(result.to_model_reply())),
                }
            )

        if cancelled:
            break
        if finish_reason == "stop":
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

    envelope = AssistantProviderEnvelope(assistant_markdown=final_text or ("Cancelled." if cancelled else "Done."))
    return AssistantTurnResult(
        target=target,
        prompt=system_prompt,
        raw_output=raw_final,
        envelope=envelope,
        provider_thread_id=None,
        tool_calls=tool_transcript,
        streamed_deltas=True,
        cancelled=cancelled,
    )


def build_planning_system_prompt(
    *, thread_title: str, planning_context: str
) -> str:
    return (
        "You are SimmerSmith's Planning Assistant, a conversational agent that helps "
        "a single user plan their week of meals.\n"
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
) -> str:
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
        body = {
            "model": target.model,
            "messages": [
                {"role": "system", "content": "Return only valid JSON matching the requested schema."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.4,
        }
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
