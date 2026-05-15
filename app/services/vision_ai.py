"""Multimodal (vision) AI calls.

Mirrors the strict-JSON pattern of `substitution_ai.py` and `event_ai.py`,
but the user-message content is a list of blocks containing a base64-encoded
image plus the prompt text. Both default models (gpt-5.4-mini and
claude-3-5-sonnet-latest) accept image inputs.

Two public functions:

- `identify_ingredient(...)` — Phase 3: photo of an ingredient → name +
  cuisine uses + recipe match terms.
- `check_cooking_progress(...)` — Phase 5: photo of a dish mid-cook +
  the recipe step → verdict + short tip.
"""
from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass

import httpx
from pydantic import BaseModel, Field, ValidationError

from app.config import Settings
from app.services.ai import (
    SUPPORTED_DIRECT_PROVIDERS,
    direct_provider_availability,
    resolve_direct_api_key,
    resolve_direct_model,
)
from app.services.assistant_ai import extract_json_object
from app.services.provider_models import openai_chat_body

logger = logging.getLogger(__name__)

# Below both providers' published limits (Anthropic ~5MB, OpenAI ~20MB).
# Keeping the same cap on both keeps the iOS client provider-agnostic.
MAX_IMAGE_BYTES = 5 * 1024 * 1024

_OPENAI_SAFE_MIMES = {"image/jpeg", "image/png", "image/webp"}
_ANTHROPIC_SAFE_MIMES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
_ACCEPTED_INPUT_MIMES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
    "image/gif",
}


class CuisineUse(BaseModel):
    country: str
    dish: str


class IngredientIdentification(BaseModel):
    name: str
    confidence: str
    common_names: list[str] = Field(default_factory=list)
    cuisine_uses: list[CuisineUse] = Field(default_factory=list)
    recipe_match_terms: list[str] = Field(default_factory=list)
    notes: str = ""


class CookCheckTip(BaseModel):
    verdict: str
    tip: str
    suggested_minutes_remaining: int = 0


@dataclass(frozen=True)
class _Target:
    provider_name: str
    model: str


def _resolve_target(settings: Settings, user_settings: dict[str, str]) -> _Target:
    preferred = str(user_settings.get("ai_direct_provider", "")).strip().lower()
    candidates: list[str] = []
    if preferred in SUPPORTED_DIRECT_PROVIDERS:
        candidates.append(preferred)
    for name in SUPPORTED_DIRECT_PROVIDERS:
        if name not in candidates:
            candidates.append(name)
    for name in candidates:
        available, _ = direct_provider_availability(
            name, settings=settings, user_settings=user_settings
        )
        if available:
            model = resolve_direct_model(name, settings=settings, user_settings=user_settings)
            return _Target(provider_name=name, model=model)
    raise RuntimeError("No vision-capable AI provider is configured.")


def _validate_image(image_bytes: bytes, mime_type: str) -> None:
    if not image_bytes:
        raise ValueError("Image data is empty.")
    if len(image_bytes) > MAX_IMAGE_BYTES:
        raise ValueError(
            f"Image is too large ({len(image_bytes)} bytes); max is {MAX_IMAGE_BYTES}."
        )
    normalized = (mime_type or "").strip().lower()
    if normalized not in _ACCEPTED_INPUT_MIMES:
        raise ValueError(f"Unsupported image MIME type: {mime_type}")


def _run_vision_provider(
    *,
    target: _Target,
    settings: Settings,
    user_settings: dict[str, str],
    system_prompt: str,
    user_prompt: str,
    image_bytes: bytes,
    mime_type: str,
) -> str:
    base64_image = base64.b64encode(image_bytes).decode("ascii")
    headers = {"Content-Type": "application/json"}
    timeout = settings.ai_timeout_seconds
    normalized_mime = (mime_type or "").strip().lower()

    if target.provider_name == "openai":
        api_mime = normalized_mime if normalized_mime in _OPENAI_SAFE_MIMES else "image/jpeg"
        headers["Authorization"] = (
            f"Bearer {resolve_direct_api_key('openai', settings=settings, user_settings=user_settings)}"
        )
        body = openai_chat_body(
            model=target.model,
            base={
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": user_prompt},
                            {
                                "type": "image_url",
                                "image_url": {"url": f"data:{api_mime};base64,{base64_image}"},
                            },
                        ],
                    },
                ],
                "temperature": 0.2,
            },
        )
        with httpx.Client(timeout=timeout) as client:
            response = client.post(
                "https://api.openai.com/v1/chat/completions",
                headers=headers,
                json=body,
            )
        response.raise_for_status()
        payload = response.json()
        return str(payload["choices"][0]["message"]["content"])

    if target.provider_name == "anthropic":
        api_mime = normalized_mime if normalized_mime in _ANTHROPIC_SAFE_MIMES else "image/jpeg"
        headers["x-api-key"] = resolve_direct_api_key(
            "anthropic", settings=settings, user_settings=user_settings
        )
        headers["anthropic-version"] = "2023-06-01"
        body = {
            "model": target.model,
            "max_tokens": 1500,
            "system": system_prompt,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": api_mime,
                                "data": base64_image,
                            },
                        },
                        {"type": "text", "text": user_prompt},
                    ],
                }
            ],
        }
        with httpx.Client(timeout=timeout) as client:
            response = client.post(
                "https://api.anthropic.com/v1/messages",
                headers=headers,
                json=body,
            )
        response.raise_for_status()
        payload = response.json()
        content = payload.get("content", [])
        text_chunks = [item.get("text", "") for item in content if item.get("type") == "text"]
        return "\n".join(chunk for chunk in text_chunks if chunk).strip()

    raise RuntimeError(f"Unsupported vision provider: {target.provider_name}")


_INGREDIENT_SYSTEM = (
    "You are a culinary expert. The user shows you a photo of an ingredient. "
    "Identify it precisely (single ingredient if clear, otherwise the most "
    "prominent one). Return ONLY a valid JSON object."
)


def _ingredient_user_prompt() -> str:
    schema = (
        '{"name": "...", "confidence": "high|medium|low", '
        '"common_names": ["..."], '
        '"cuisine_uses": [{"country": "...", "dish": "..."}], '
        '"recipe_match_terms": ["..."], '
        '"notes": "..."}'
    )
    return (
        "Identify the ingredient in this photo.\n\n"
        "Rules:\n"
        "- `name` is the most common English name (e.g., 'habanero pepper', 'Thai basil').\n"
        "- `confidence` reflects how certain you are: 'high' if obvious, 'medium' if "
        "narrowed but ambiguous, 'low' if you can only guess.\n"
        "- `common_names` lists alternate names across regions/languages (max 4).\n"
        "- `cuisine_uses` lists 2–4 (country, dish) pairs showing how it's used.\n"
        "- `recipe_match_terms` lists 2–6 short search keywords (e.g., 'jalapeno', "
        "'chili pepper'). Useful for matching against a recipe library.\n"
        "- `notes` is one short sentence with handling or substitution tips. Empty if "
        "nothing notable.\n\n"
        f"Return ONLY JSON matching:\n{schema}"
    )


def identify_ingredient(
    *,
    image_bytes: bytes,
    mime_type: str,
    settings: Settings,
    user_settings: dict[str, str],
) -> IngredientIdentification:
    """Identify the ingredient in a photo. Returns a structured response."""
    _validate_image(image_bytes, mime_type)
    target = _resolve_target(settings, user_settings)
    raw = _run_vision_provider(
        target=target,
        settings=settings,
        user_settings=user_settings,
        system_prompt=_INGREDIENT_SYSTEM,
        user_prompt=_ingredient_user_prompt(),
        image_bytes=image_bytes,
        mime_type=mime_type,
    )
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for ingredient identification.") from exc
    try:
        return IngredientIdentification.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI response did not match the expected shape.") from exc


_COOK_CHECK_SYSTEM = (
    "You are a calm, helpful cooking coach. The user shows you a photo of "
    "their dish mid-cook and tells you the recipe step they are on. Reply with "
    "a single short tip and a verdict. Return ONLY a valid JSON object."
)


def _cook_check_user_prompt(
    *, recipe_title: str, step_text: str, recipe_context: str
) -> str:
    schema = (
        '{"verdict": "on_track|needs_more_time|concerning", '
        '"tip": "...", "suggested_minutes_remaining": 0}'
    )
    context_block = recipe_context.strip()
    context_line = f"Recipe context: {context_block}\n" if context_block else ""
    return (
        f"Recipe: {recipe_title.strip() or '(untitled)'}\n"
        f"Current step: {step_text.strip() or '(no step text)'}\n"
        f"{context_line}\n"
        "Look at the photo and judge whether the cook is on track for this step.\n\n"
        "Rules:\n"
        "- `verdict` must be one of: 'on_track', 'needs_more_time', 'concerning'.\n"
        "- `tip` is one or two short sentences in plain, encouraging English.\n"
        "- `suggested_minutes_remaining` is a non-negative integer (0 if it's done).\n\n"
        f"Return ONLY JSON matching:\n{schema}"
    )


def check_cooking_progress(
    *,
    image_bytes: bytes,
    mime_type: str,
    recipe_title: str,
    step_text: str,
    recipe_context: str,
    settings: Settings,
    user_settings: dict[str, str],
) -> CookCheckTip:
    """Look at a mid-cook photo and return a short verdict + tip."""
    _validate_image(image_bytes, mime_type)
    target = _resolve_target(settings, user_settings)
    raw = _run_vision_provider(
        target=target,
        settings=settings,
        user_settings=user_settings,
        system_prompt=_COOK_CHECK_SYSTEM,
        user_prompt=_cook_check_user_prompt(
            recipe_title=recipe_title,
            step_text=step_text,
            recipe_context=recipe_context,
        ),
        image_bytes=image_bytes,
        mime_type=mime_type,
    )
    candidate = extract_json_object(raw)
    try:
        payload = json.loads(candidate)
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI returned invalid JSON for cook check.") from exc
    try:
        return CookCheckTip.model_validate(payload)
    except ValidationError as exc:
        raise RuntimeError("AI response did not match the expected shape.") from exc
