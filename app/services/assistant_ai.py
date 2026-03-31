from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass

import httpx
from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.schemas import AssistantRespondRequest, RecipePayload
from app.services.ai import SUPPORTED_DIRECT_PROVIDERS, direct_provider_availability, resolve_direct_api_key, resolve_direct_model
from app.services.mcp_client import run_codex_mcp


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
) -> AssistantTurnResult:
    target = resolve_assistant_execution_target(
        settings,
        user_settings,
        existing_provider_thread_id=existing_provider_thread_id,
    )
    prompt = build_assistant_prompt(
        thread_title=thread_title,
        conversation=conversation,
        request=request,
        attached_recipe=attached_recipe,
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


def build_assistant_prompt(
    *,
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None,
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
