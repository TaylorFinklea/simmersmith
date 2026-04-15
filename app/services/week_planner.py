"""AI week planner — generates a full week of meals from a user prompt.

Takes the user's description + profile context, calls an AI provider,
parses the structured JSON response, and returns a DraftFromAIRequest
ready to be applied via apply_ai_draft.
"""
from __future__ import annotations

import json
import logging
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, timedelta

import httpx
from sqlalchemy.orm import Session

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


@dataclass
class PlanningContext:
    """Structured context gathered from the DB for prompt enrichment."""

    hard_avoids: list[str] = field(default_factory=list)
    strong_likes: list[str] = field(default_factory=list)
    liked_cuisines: list[str] = field(default_factory=list)
    disliked_cuisines: list[str] = field(default_factory=list)
    brands: list[str] = field(default_factory=list)
    staples: list[str] = field(default_factory=list)
    recent_meals: list[str] = field(default_factory=list)
    rules: list[str] = field(default_factory=list)


def gather_planning_context(
    session: Session, user_id: str, exclude_week_id: str | None = None,
) -> PlanningContext:
    """Fetch preference signals, staples, and recent meal history from the DB."""
    from app.services.grocery import staple_names
    from app.services.preferences import list_preference_signals, preference_summary_payload
    from app.services.weeks import list_weeks

    summary = preference_summary_payload(session, user_id)
    signals = list_preference_signals(session, user_id)
    active_signals = [s for s in signals if s.active]

    liked_cuisines = sorted(
        s.name for s in active_signals if s.signal_type == "cuisine" and s.score > 0
    )
    disliked_cuisines = sorted(
        s.name for s in active_signals if s.signal_type == "cuisine" and s.score < 0
    )

    pantry = sorted(staple_names(session, user_id))

    recent_weeks = list_weeks(session, user_id, limit=4)
    seen: set[str] = set()
    recent_meal_names: list[str] = []
    for week in recent_weeks:
        if exclude_week_id and str(week.id) == str(exclude_week_id):
            continue
        for meal in week.meals:
            name = (meal.recipe_name or "").strip()
            if name and name not in seen:
                seen.add(name)
                recent_meal_names.append(name)

    return PlanningContext(
        hard_avoids=summary["hard_avoids"],
        strong_likes=summary["strong_likes"],
        liked_cuisines=liked_cuisines,
        disliked_cuisines=disliked_cuisines,
        brands=summary["brands"],
        staples=pantry,
        recent_meals=recent_meal_names[:60],
        rules=summary["rules"],
    )


def _build_system_prompt(
    user_settings: dict[str, str],
    week_start: date,
    context: PlanningContext | None = None,
) -> str:
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

    # Build optional context sections
    context_sections = ""
    if context:
        sections: list[str] = []

        # Preference signals
        pref_lines: list[str] = []
        if context.hard_avoids:
            pref_lines.append(f"- MUST AVOID: {', '.join(context.hard_avoids)}")
        if context.strong_likes:
            pref_lines.append(f"- Strongly likes: {', '.join(context.strong_likes)}")
        if context.brands:
            pref_lines.append(f"- Preferred brands: {', '.join(context.brands)}")
        if context.liked_cuisines:
            pref_lines.append(f"- Liked cuisines: {', '.join(context.liked_cuisines)}")
        if context.disliked_cuisines:
            pref_lines.append(f"- Disliked cuisines: {', '.join(context.disliked_cuisines)}")
        if pref_lines:
            sections.append("Preference signals:\n" + "\n".join(pref_lines))

        # Pantry staples
        if context.staples:
            sections.append(
                "Pantry staples (always available, use freely):\n"
                + ", ".join(context.staples)
            )

        # Recent meal history
        if context.recent_meals:
            sections.append(
                "Recent meals (avoid repeating these for variety):\n"
                + ", ".join(context.recent_meals)
            )

        if sections:
            context_sections = "\n\n" + "\n\n".join(sections)

    # Build enhanced rules when context is present
    extra_rules = ""
    if context:
        extra_lines: list[str] = []
        if context.hard_avoids:
            extra_lines.append(
                "- NEVER include ingredients from the MUST AVOID list"
            )
        if context.strong_likes or context.liked_cuisines:
            extra_lines.append(
                "- Favor ingredients and cuisines the household strongly likes"
            )
        if context.disliked_cuisines:
            extra_lines.append(
                "- Avoid cuisines the household dislikes unless specifically requested"
            )
        if context.recent_meals:
            extra_lines.append(
                "- Avoid repeating any meal from the recent meals list above"
            )
        extra_lines.append(
            "- A single recipe may appear at most 3 times in one week (e.g., leftovers)"
        )
        if context.staples:
            extra_lines.append(
                "- Leverage pantry staples when possible to reduce grocery costs"
            )
        if extra_lines:
            extra_rules = "\n" + "\n".join(extra_lines)

    dates = [(week_start + timedelta(days=i)) for i in range(7)]
    day_labels = [f"{DAYS[i]} ({dates[i].isoformat()})" for i in range(7)]

    return f"""You are SimmerSmith, an AI meal planning assistant.

Generate a complete 7-day meal plan based on the user's request and their profile.

User profile:
{profile_block}{context_sections}

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
- Vary cuisines and cooking styles across the week{extra_rules}"""


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


def validate_plan_guardrails(
    plan: dict, context: PlanningContext | None = None,
) -> list[str]:
    """Check a generated plan for quality issues. Returns warning strings."""
    warnings: list[str] = []
    meal_plan = plan.get("meal_plan", [])
    recipes = plan.get("recipes", [])

    # Check recipe reuse — max 3 appearances per week
    name_counts = Counter(m.get("recipe_name", "") for m in meal_plan)
    for name, count in name_counts.items():
        if count > 3:
            warnings.append(f"Recipe '{name}' appears {count} times (max 3 recommended)")

    if not context:
        return warnings

    # Check for recent meal repeats
    recent_lower = {m.lower() for m in context.recent_meals}
    for name in name_counts:
        if name.lower() in recent_lower:
            warnings.append(f"Recipe '{name}' was served recently")

    # Check for avoided ingredients
    avoids_lower = {a.lower() for a in context.hard_avoids}
    if avoids_lower:
        for recipe in recipes:
            for ing in recipe.get("ingredients", []):
                ing_name = (ing.get("ingredient_name") or "").lower()
                for avoid in avoids_lower:
                    if avoid in ing_name:
                        warnings.append(
                            f"Recipe '{recipe.get('name')}' contains avoided ingredient '{ing_name}'"
                        )

    return warnings


def score_generated_plan(
    session: Session, user_id: str, plan: dict,
) -> dict:
    """Score each recipe in a generated plan against user preference signals."""
    from app.schemas import MealScoreRequest
    from app.services.preferences import score_meal_candidate

    recipes = plan.get("recipes", [])
    meal_scores: list[dict] = []
    total: int = 0
    blocked: list[str] = []

    for recipe in recipes:
        payload = MealScoreRequest(
            recipe_name=recipe.get("name", ""),
            cuisine=recipe.get("cuisine", ""),
            meal_type=recipe.get("meal_type", ""),
            ingredient_names=[
                ing.get("ingredient_name", "")
                for ing in recipe.get("ingredients", [])
            ],
        )
        result = score_meal_candidate(session, user_id, payload)
        raw_score = result.get("total_score", 0)
        recipe_score = raw_score if isinstance(raw_score, int) else int(raw_score or 0)
        score_entry = {
            "recipe_name": recipe.get("name", ""),
            "total_score": recipe_score,
            "blocked": result["blocked"],
        }
        meal_scores.append(score_entry)
        total += recipe_score
        if result["blocked"]:
            blocked.append(recipe.get("name", ""))

    return {
        "meal_scores": meal_scores,
        "plan_total_score": total,
        "blocked_meals": blocked,
    }


def generate_week_plan(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    user_prompt: str,
    week_start: date,
    planning_context: PlanningContext | None = None,
) -> dict:
    """Generate a full week meal plan via AI.

    Returns a dict matching the DraftFromAIRequest schema, ready to be
    validated and applied via apply_ai_draft.
    """
    system_prompt = _build_system_prompt(user_settings, week_start, context=planning_context)

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

    # Run guardrail validation
    guardrail_warnings = validate_plan_guardrails(plan, planning_context)
    week_notes = "; ".join(guardrail_warnings) if guardrail_warnings else ""
    if guardrail_warnings:
        logger.warning("Plan guardrail warnings: %s", guardrail_warnings)

    return {
        "prompt": user_prompt,
        "model": "week-planner",
        "recipes": recipes,
        "meal_plan": meal_plan,
        "week_notes": week_notes,
    }
