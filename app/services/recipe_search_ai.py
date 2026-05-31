"""AI recipe web search (M12 Phase 4).

Searches the web for a real recipe and returns it as a `RecipePayload`
with the cited `source_url` preserved.

Two providers, picked per-user via the `recipe_search_provider` row in
`profile_settings` (falls back to `settings.ai_recipe_search_provider`,
which defaults to "openai"):

- **OpenAI** uses the Responses API with the `web_search` tool.
- **Anthropic** uses the Messages API with the `web_search_20250305`
  tool.

Both providers return the same `_AIRecipe` shape and pass through the
same `_to_recipe_payload` mapper, so the rest of the codebase doesn't
care which one answered.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any

import httpx
from pydantic import BaseModel, Field, ValidationError

from app.config import Settings
from app.schemas import RecipePayload
from app.schemas.recipe import RecipeIngredientPayload, RecipeStepPayload
from app.services.ai import (
    direct_provider_availability,
    resolve_direct_api_key,
    resolve_direct_model,
)
from app.services.assistant_ai import extract_json_object

logger = logging.getLogger(__name__)

OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"

_VALID_PROVIDERS = ("openai", "anthropic")


class _AIIngredient(BaseModel):
    ingredient_name: str
    quantity: float | None = None
    unit: str = ""
    prep: str = ""


class _AIStep(BaseModel):
    step_number: int = 0
    instruction: str


class _AIRecipe(BaseModel):
    """Strict shape we ask the model to return. We then map this to the
    canonical `RecipePayload`. Kept separate so a schema rev here doesn't
    leak into the rest of the codebase."""

    name: str
    source_url: str = ""
    source_label: str = ""
    cuisine: str = ""
    meal_type: str = ""
    servings: float | None = None
    prep_minutes: int | None = None
    cook_minutes: int | None = None
    ingredients: list[_AIIngredient] = Field(default_factory=list)
    steps: list[_AIStep] = Field(default_factory=list)
    notes: str = ""


@dataclass(frozen=True)
class _Target:
    provider: str
    model: str


def _resolve_provider(
    settings: Settings, user_settings: dict[str, str]
) -> str:
    """Pick the provider for this call. User's `recipe_search_provider`
    profile row wins when valid; otherwise fall back to the global
    `ai_recipe_search_provider` setting; otherwise "openai".

    Mirrors the resolution pattern in `recipe_image_ai._resolve_provider`.
    """
    user_choice = str((user_settings or {}).get("recipe_search_provider", "")).strip().lower()
    if user_choice in _VALID_PROVIDERS:
        return user_choice
    global_choice = str(settings.ai_recipe_search_provider or "").strip().lower()
    if global_choice in _VALID_PROVIDERS:
        return global_choice
    return "openai"


def _resolve_target(settings: Settings, user_settings: dict[str, str]) -> _Target:
    provider = _resolve_provider(settings, user_settings)
    available, _ = direct_provider_availability(
        provider, settings=settings, user_settings=user_settings
    )
    if not available:
        nice_name = "Anthropic" if provider == "anthropic" else "OpenAI"
        key_env = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
        raise RuntimeError(
            f"AI recipe web search is set to {nice_name} but no key is configured. "
            f"Add your {key_env} in Settings → AI, or pick the other provider."
        )
    model = resolve_direct_model(provider, settings=settings, user_settings=user_settings)
    return _Target(provider=provider, model=model)


def _build_input(query: str, *, user_settings: dict[str, str]) -> str:
    from app.services.ai import unit_system_directive

    units_directive = unit_system_directive(user_settings)
    schema_hint = (
        '{"name": "...", "source_url": "https://...", "source_label": "site name", '
        '"cuisine": "...", "meal_type": "breakfast|lunch|dinner|snack|dessert", '
        '"servings": 4, "prep_minutes": 15, "cook_minutes": 30, '
        '"ingredients": [{"ingredient_name": "all-purpose flour", "quantity": 1.5, '
        '"unit": "cup", "prep": "sifted"}], '
        '"steps": [{"step_number": 0, "instruction": "..."}], '
        '"notes": "Why this recipe is the pick"}'
    )
    return (
        f"{units_directive}\n\n"
        "You are a recipe finder. Use web search to find the BEST recipe that "
        f"matches this request: {query.strip()}\n\n"
        "Pick exactly ONE recipe — the one you'd recommend after looking at a "
        "handful of options. Prefer recipes from reputable sources (NYT Cooking, "
        "Serious Eats, Bon Appétit, King Arthur, AllRecipes high-rated, food "
        "blogs with established readership) over content farms.\n\n"
        "Then extract the full recipe — title, ingredients with quantities + "
        "units, ordered steps, prep/cook minutes, servings, cuisine, meal type "
        "— into a single JSON object. The `source_url` must be the real URL of "
        "the recipe you picked, and `source_label` is the site name (e.g., "
        "'NYT Cooking', 'Serious Eats').\n\n"
        "In `notes`, write 1–2 sentences explaining why this recipe stood out "
        "(e.g., 'Highest-rated whole wheat waffle on Serious Eats — yeast-raised "
        "for crisp edges').\n\n"
        "Return ONLY a JSON object matching this schema:\n"
        f"{schema_hint}\n"
    )


# ---------------------------------------------------------------------
# OpenAI Responses API (web_search tool)
# ---------------------------------------------------------------------


def _extract_text_from_openai_payload(payload: dict[str, Any]) -> str:
    """Pull the model's text output from the OpenAI Responses payload.

    Shape: a list of `output` items — `web_search_call` (skipped) and
    one or more `message` items whose `content` is a list of text
    blocks. We concatenate all `output_text` / `text` values.
    """
    if "output_text" in payload and isinstance(payload["output_text"], str):
        return str(payload["output_text"])
    chunks: list[str] = []
    for item in payload.get("output", []):
        if not isinstance(item, dict):
            continue
        if item.get("type") != "message":
            continue
        for block in item.get("content", []):
            if isinstance(block, dict) and block.get("type") in {"output_text", "text"}:
                text = block.get("text") or ""
                if isinstance(text, str) and text:
                    chunks.append(text)
    return "\n".join(chunks).strip()


def _search_openai(
    *,
    query: str,
    target: _Target,
    settings: Settings,
    user_settings: dict[str, str],
) -> str:
    api_key = resolve_direct_api_key("openai", settings=settings, user_settings=user_settings)
    body = {
        "model": target.model,
        "input": _build_input(query, user_settings=user_settings),
        "tools": [{"type": "web_search"}],
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    timeout = max(settings.ai_timeout_seconds, 90)
    with httpx.Client(timeout=timeout) as client:
        response = client.post(OPENAI_RESPONSES_URL, headers=headers, json=body)
    try:
        response.raise_for_status()
    except httpx.HTTPError as exc:
        # Map provider 401/429/5xx to RuntimeError -> 502 at the route (M6).
        raise RuntimeError(f"AI provider request failed: {exc}") from exc
    return _extract_text_from_openai_payload(response.json())


# ---------------------------------------------------------------------
# Anthropic Messages API (web_search_20250305 tool)
# ---------------------------------------------------------------------


def _extract_text_from_anthropic_payload(payload: dict[str, Any]) -> str:
    """Pull the model's final-answer text from Anthropic Messages payload.

    Shape: `content` is a list of blocks; web_search introduces
    `server_tool_use` + `web_search_tool_result` blocks before the final
    `text` block. Skip the tool blocks, concat the text blocks.
    """
    chunks: list[str] = []
    for block in payload.get("content", []):
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            text = block.get("text") or ""
            if isinstance(text, str) and text:
                chunks.append(text)
    return "\n".join(chunks).strip()


def _search_anthropic(
    *,
    query: str,
    target: _Target,
    settings: Settings,
    user_settings: dict[str, str],
) -> str:
    api_key = resolve_direct_api_key("anthropic", settings=settings, user_settings=user_settings)
    body = {
        "model": target.model,
        "max_tokens": 4096,
        # `max_uses` caps the number of search subqueries — keeps cost
        # bounded if the model gets indecisive between candidate recipes.
        "tools": [{"type": "web_search_20250305", "name": "web_search", "max_uses": 5}],
        "messages": [
            {"role": "user", "content": _build_input(query, user_settings=user_settings)},
        ],
    }
    headers = {
        "x-api-key": api_key,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
    }
    timeout = max(settings.ai_timeout_seconds, 90)
    with httpx.Client(timeout=timeout) as client:
        response = client.post(ANTHROPIC_MESSAGES_URL, headers=headers, json=body)
    try:
        response.raise_for_status()
    except httpx.HTTPError as exc:
        raise RuntimeError(f"AI provider request failed: {exc}") from exc
    return _extract_text_from_anthropic_payload(response.json())


# ---------------------------------------------------------------------
# Public entry + payload mapper
# ---------------------------------------------------------------------


def _to_recipe_payload(parsed: _AIRecipe) -> RecipePayload:
    return RecipePayload(
        name=parsed.name.strip() or "Untitled",
        cuisine=parsed.cuisine.strip(),
        meal_type=parsed.meal_type.strip().lower(),
        servings=parsed.servings,
        prep_minutes=parsed.prep_minutes,
        cook_minutes=parsed.cook_minutes,
        tags=[],
        instructions_summary="",
        favorite=False,
        source="ai_web_search",
        source_label=parsed.source_label.strip(),
        source_url=parsed.source_url.strip(),
        notes=parsed.notes.strip(),
        memories="",
        last_used=None,
        ingredients=[
            RecipeIngredientPayload(
                ingredient_name=ing.ingredient_name.strip(),
                quantity=ing.quantity,
                unit=ing.unit.strip(),
                prep=ing.prep.strip(),
            )
            for ing in parsed.ingredients
            if ing.ingredient_name.strip()
        ],
        steps=[
            RecipeStepPayload(
                sort_order=idx,
                instruction=step.instruction.strip(),
            )
            for idx, step in enumerate(parsed.steps)
            if step.instruction.strip()
        ],
        nutrition_summary=None,
    )


def search_recipe(
    *,
    query: str,
    settings: Settings,
    user_settings: dict[str, str],
) -> RecipePayload:
    """Search the web for a real recipe and return it as a `RecipePayload`.

    Dispatches to OpenAI or Anthropic based on the resolved provider
    (user setting wins over global; defaults to OpenAI). Raises
    `RuntimeError` if the chosen provider has no API key configured
    or the response can't be parsed.
    """
    if not query.strip():
        raise ValueError("Search query is empty.")
    target = _resolve_target(settings, user_settings)
    if target.provider == "anthropic":
        raw_text = _search_anthropic(
            query=query, target=target, settings=settings, user_settings=user_settings
        )
    else:
        raw_text = _search_openai(
            query=query, target=target, settings=settings, user_settings=user_settings
        )

    if not raw_text:
        raise RuntimeError("AI web search returned no text output.")

    candidate = extract_json_object(raw_text)
    try:
        parsed = _AIRecipe.model_validate(json.loads(candidate))
    except json.JSONDecodeError as exc:
        raise RuntimeError("AI web search returned invalid JSON.") from exc
    except ValidationError as exc:
        raise RuntimeError("AI web search response did not match the expected shape.") from exc

    return _to_recipe_payload(parsed)
