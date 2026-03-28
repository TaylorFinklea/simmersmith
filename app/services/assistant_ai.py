from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass

import httpx
from pydantic import BaseModel, ValidationError

from app.config import Settings
from app.schemas import AssistantRespondRequest, RecipePayload
from app.services.ai import SUPPORTED_DIRECT_PROVIDERS, direct_provider_availability


class AssistantProviderEnvelope(BaseModel):
    assistant_markdown: str
    recipe_draft: RecipePayload | None = None


@dataclass(frozen=True)
class AssistantExecutionTarget:
    provider_kind: str
    source: str
    model: str
    provider_name: str | None = None
    cli_path: str | None = None

    def as_payload(self) -> dict[str, object]:
        return {
            "provider_kind": self.provider_kind,
            "source": self.source,
            "model": self.model,
            "provider_name": self.provider_name,
            "cli_path": self.cli_path,
        }


@dataclass(frozen=True)
class AssistantTurnResult:
    target: AssistantExecutionTarget
    prompt: str
    raw_output: str
    envelope: AssistantProviderEnvelope


def resolve_assistant_execution_target(settings: Settings, user_settings: dict[str, str]) -> AssistantExecutionTarget:
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
        model = settings.ai_openai_model if provider_name == "openai" else settings.ai_anthropic_model
        return AssistantExecutionTarget(
            provider_kind="direct",
            source=source,
            provider_name=provider_name,
            model=model,
        )

    cli_path = shutil.which(settings.ai_codex_cli_path) or (
        settings.ai_codex_cli_path if shutil.which(settings.ai_codex_cli_path) else None
    )
    if cli_path:
        return AssistantExecutionTarget(
            provider_kind="codex_cli",
            source="server_codex_cli",
            provider_name="codex",
            model="codex",
            cli_path=cli_path,
        )
    raise RuntimeError("No AI provider is configured and codex CLI is not available on the server.")


def run_assistant_turn(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None = None,
) -> AssistantTurnResult:
    target = resolve_assistant_execution_target(settings, user_settings)
    prompt = build_assistant_prompt(
        thread_title=thread_title,
        conversation=conversation,
        request=request,
        attached_recipe=attached_recipe,
    )
    if target.provider_kind == "direct":
        raw_output = run_direct_provider(target=target, settings=settings, user_settings=user_settings, prompt=prompt)
    else:
        raw_output = run_codex_cli(target=target, settings=settings, prompt=prompt)
    envelope = parse_provider_envelope(raw_output)
    return AssistantTurnResult(target=target, prompt=prompt, raw_output=raw_output, envelope=envelope)


def build_assistant_prompt(
    *,
    thread_title: str,
    conversation: list[dict[str, object]],
    request: AssistantRespondRequest,
    attached_recipe: RecipePayload | None,
) -> str:
    envelope_schema = json.dumps(AssistantProviderEnvelope.model_json_schema(), indent=2)
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
        "Never claim to have saved or published anything.\n"
        "You may optionally include one recipe_draft when the user asks for recipe creation or recipe refinement.\n"
        "If you include a recipe_draft, it must be complete enough to open in an editor.\n"
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


def run_codex_cli(*, target: AssistantExecutionTarget, settings: Settings, prompt: str) -> str:
    if not target.cli_path:
        raise RuntimeError("codex CLI path is unavailable.")
    schema = AssistantProviderEnvelope.model_json_schema()
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as schema_file:
        json.dump(schema, schema_file)
        schema_path = schema_file.name
    with tempfile.NamedTemporaryFile("w+", suffix=".json", delete=False) as output_file:
        output_path = output_file.name
    try:
        command = [
            target.cli_path,
            "exec",
            prompt,
            "--ephemeral",
            "--skip-git-repo-check",
            "--output-schema",
            schema_path,
            "--output-last-message",
            output_path,
        ]
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=settings.ai_timeout_seconds,
            check=False,
        )
        if completed.returncode != 0:
            stderr = completed.stderr.strip() or completed.stdout.strip() or "codex exec failed"
            raise RuntimeError(stderr)
        with open(output_path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    finally:
        for path in (schema_path, output_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


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


def resolve_direct_api_key(provider_name: str, *, settings: Settings, user_settings: dict[str, str]) -> str:
    preferred_provider = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    override_key = str(user_settings.get("ai_direct_api_key", "")).strip()
    if preferred_provider == provider_name and override_key:
        return override_key
    if provider_name == "openai":
        return settings.ai_openai_api_key.strip()
    if provider_name == "anthropic":
        return settings.ai_anthropic_api_key.strip()
    return ""
