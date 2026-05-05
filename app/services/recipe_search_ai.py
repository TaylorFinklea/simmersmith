"""AI recipe web search (M12 Phase 4).

Uses OpenAI's Responses API with the `web_search` tool to find a real
recipe online and return it as a `RecipePayload`. The cited source URL
is preserved on the recipe so the user knows where it came from.

Anthropic's Messages web-search tool is a future follow-up — for now,
this feature requires an OpenAI key. If only Anthropic is configured,
we raise a helpful error rather than silently degrade.
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
    model: str


def _resolve_openai_target(settings: Settings, user_settings: dict[str, str]) -> _Target:
    available, _ = direct_provider_availability(
        "openai", settings=settings, user_settings=user_settings
    )
    if not available:
        raise RuntimeError(
            "AI recipe web search requires OpenAI. Add your OPENAI_API_KEY in "
            "Settings → AI."
        )
    model = resolve_direct_model("openai", settings=settings, user_settings=user_settings)
    return _Target(model=model)


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


def _extract_text_from_responses_payload(payload: dict[str, Any]) -> str:
    """Pull the model's text output from the Responses API payload.

    The shape is a list of `output` items: web_search_call entries (skipped)
    and a `message` entry whose `content` is a list of text blocks. We
    concatenate all `output_text` values.
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

    Currently uses OpenAI's Responses API (`web_search` tool). Anthropic
    web-search support is a future follow-up. Raises RuntimeError if no
    OpenAI provider is configured or the response cannot be parsed.
    """
    if not query.strip():
        raise ValueError("Search query is empty.")
    target = _resolve_openai_target(settings, user_settings)
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
    response.raise_for_status()
    payload = response.json()

    raw_text = _extract_text_from_responses_payload(payload)
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
