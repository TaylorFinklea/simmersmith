"""AI week planner — generates a full week of meals from a user prompt.

Takes the user's description + profile context, calls an AI provider,
parses the structured JSON response, and returns a DraftFromAIRequest
ready to be applied via apply_ai_draft.
"""
from __future__ import annotations

import json
import logging
from datetime import date, timedelta

import httpx

from app.config import Settings
from app.services.ai import (
    resolve_ai_execution_target,
    resolve_direct_api_key,
    resolve_direct_model,
    visible_profile_settings,
)

logger = logging.getLogger(__name__)

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
SLOTS = ["breakfast", "lunch", "dinner"]


def _build_system_prompt(user_settings: dict[str, str], week_start: date) -> str:
    profile_ctx = visible_profile_settings(user_settings)
    profile_lines = []
    for key in [
        "household_name", "household_adults", "household_kids",
        "dietary_constraints", "cuisine_preferences", "budget_notes",
        "food_principles", "convenience_rules", "breakfast_strategy",
        "lunch_strategy", "snack_strategy", "leftovers_policy",
        "planning_avoids",
    ]:
        val = profile_ctx.get(key, "").strip()
        if val:
            label = key.replace("_", " ").title()
            profile_lines.append(f"- {label}: {val}")
    profile_block = "\n".join(profile_lines) if profile_lines else "(no preferences set)"

    dates = [(week_start + timedelta(days=i)) for i in range(7)]
    day_labels = [f"{DAYS[i]} ({dates[i].isoformat()})" for i in range(7)]

    return f"""You are SimmerSmith, an AI meal planning assistant.

Generate a complete 7-day meal plan based on the user's request and their profile.

User profile:
{profile_block}

Week: {day_labels[0]} through {day_labels[6]}

Return ONLY valid JSON with this exact structure:
{{
  "recipes": [
    {{
      "name": "Recipe Name",
      "meal_type": "dinner",
      "cuisine": "Italian",
      "servings": 4,
      "prep_minutes": 15,
      "cook_minutes": 30,
      "ingredients": [
        {{"ingredient_name": "chicken breast", "quantity": 2.0, "unit": "lb", "prep": "cubed", "category": "protein"}}
      ],
      "steps": [
        {{"instruction": "Step 1 description"}},
        {{"instruction": "Step 2 description"}}
      ]
    }}
  ],
  "meal_plan": [
    {{"day_name": "Monday", "meal_date": "{dates[0].isoformat()}", "slot": "breakfast", "recipe_name": "Recipe Name"}},
    {{"day_name": "Monday", "meal_date": "{dates[0].isoformat()}", "slot": "lunch", "recipe_name": "Recipe Name"}},
    {{"day_name": "Monday", "meal_date": "{dates[0].isoformat()}", "slot": "dinner", "recipe_name": "Recipe Name"}}
  ]
}}

Rules:
- Generate 3 meals per day (breakfast, lunch, dinner) for all 7 days = 21 meals total
- Each recipe_name in meal_plan must match exactly one recipe in the recipes array
- Recipes can be reused across multiple meals (e.g., leftovers)
- Include realistic ingredients with quantities and units
- Include clear, numbered cooking steps
- Respect the user's dietary constraints and preferences
- Vary cuisines and cooking styles across the week"""


def _call_ai_provider(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    system_prompt: str,
    user_prompt: str,
) -> str:
    """Call the AI provider and return the raw response text."""
    target = resolve_ai_execution_target(settings, user_settings)
    if target is None:
        raise RuntimeError(
            "No AI provider configured. Set SIMMERSMITH_AI_OPENAI_API_KEY or "
            "SIMMERSMITH_AI_ANTHROPIC_API_KEY on the server."
        )

    provider = target.provider_name
    if provider not in ("openai", "anthropic"):
        raise RuntimeError(f"Week planning requires a direct AI provider, got: {target.mode}")

    model = resolve_direct_model(provider, settings=settings, user_settings=user_settings)
    api_key = resolve_direct_api_key(provider, settings=settings, user_settings=user_settings)
    timeout = settings.ai_timeout_seconds

    headers = {"Content-Type": "application/json"}

    if provider == "openai":
        headers["Authorization"] = f"Bearer {api_key}"
        body = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.7,
            "response_format": {"type": "json_object"},
        }
        with httpx.Client(timeout=timeout) as client:
            response = client.post("https://api.openai.com/v1/chat/completions", headers=headers, json=body)
        response.raise_for_status()
        return str(response.json()["choices"][0]["message"]["content"])

    if provider == "anthropic":
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
        body = {
            "model": model,
            "max_tokens": 8000,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_prompt}],
        }
        with httpx.Client(timeout=timeout) as client:
            response = client.post("https://api.anthropic.com/v1/messages", headers=headers, json=body)
        response.raise_for_status()
        content = response.json().get("content", [])
        return "\n".join(item.get("text", "") for item in content if item.get("type") == "text").strip()

    raise RuntimeError(f"Unsupported provider: {provider}")


def _extract_json(raw: str) -> dict:
    """Extract JSON from AI response, handling markdown code fences."""
    text = raw.strip()
    if text.startswith("```"):
        lines = text.split("\n")
        # Drop opening ``` line and closing ``` line
        lines = [line for line in lines[1:] if not line.strip().startswith("```")]
        text = "\n".join(lines)
    return json.loads(text)


def generate_week_plan(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    user_prompt: str,
    week_start: date,
) -> dict:
    """Generate a full week meal plan via AI.

    Returns a dict matching the DraftFromAIRequest schema, ready to be
    validated and applied via apply_ai_draft.
    """
    system_prompt = _build_system_prompt(user_settings, week_start)

    raw = _call_ai_provider(
        settings=settings,
        user_settings=user_settings,
        system_prompt=system_prompt,
        user_prompt=user_prompt or "Plan a balanced, varied week of meals.",
    )

    try:
        plan = _extract_json(raw)
    except json.JSONDecodeError as exc:
        logger.error("AI returned invalid JSON for week plan: %s", raw[:500])
        raise RuntimeError("AI returned an invalid meal plan. Please try again.") from exc

    # Normalize into DraftFromAIRequest shape
    recipes = plan.get("recipes", [])
    meal_plan = plan.get("meal_plan", [])

    # Ensure each recipe has required fields
    for recipe in recipes:
        recipe.setdefault("ingredients", [])
        recipe.setdefault("steps", [])
        recipe.setdefault("meal_type", "")
        recipe.setdefault("cuisine", "")
        recipe.setdefault("servings", None)
        recipe.setdefault("prep_minutes", None)
        recipe.setdefault("cook_minutes", None)

    # Ensure each meal has required fields
    for meal in meal_plan:
        meal.setdefault("source", "ai")
        meal.setdefault("approved", False)
        meal.setdefault("notes", "")
        meal.setdefault("ingredients", [])

    return {
        "prompt": user_prompt,
        "model": "week-planner",
        "recipes": recipes,
        "meal_plan": meal_plan,
        "week_notes": "",
    }
