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
    unit_system_directive,
    visible_profile_settings,
)

logger = logging.getLogger(__name__)

DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
SLOTS = ["breakfast", "lunch", "dinner"]


@dataclass
class DietaryGoalContext:
    """Snapshot of a user's daily calorie + macro target."""

    goal_type: str = "maintain"
    daily_calories: int = 0
    protein_g: int = 0
    carbs_g: int = 0
    fat_g: int = 0
    fiber_g: int | None = None
    notes: str = ""


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
    dietary_goal: DietaryGoalContext | None = None
    # Catalog-level ingredient allergies (IngredientPreference.choice_mode
    # == "allergy"). Surfaced as a separate, more-emphasized line in the
    # system prompt than regular avoids.
    allergies: list[str] = field(default_factory=list)
    # M26 Phase 3 — household-level shorthand aliases (e.g. "chx" →
    # "chicken"). Injected as a preamble in the system prompt so the AI
    # treats the term as if the user typed the expansion.
    term_aliases: dict[str, str] = field(default_factory=dict)


def gather_planning_context(
    session: Session,
    user_id: str,
    exclude_week_id: str | None = None,
    *,
    household_id: str | None = None,
) -> PlanningContext:
    """Fetch preference signals, staples, recent meal history, and dietary goal."""
    from app.services.grocery import staple_names
    from app.services.ingredient_catalog.variation import list_ingredient_preferences
    from app.services.preferences import list_preference_signals, preference_summary_payload
    from app.services.profile import get_dietary_goal
    from app.services.weeks import list_weeks

    summary = preference_summary_payload(session, user_id)
    signals = list_preference_signals(session, user_id)
    active_signals = [s for s in signals if s.active]

    # Catalog-level avoid / allergy preferences (IngredientPreference).
    # Today these are the ONLY source of structured per-ingredient avoids —
    # PreferenceSignal is coarser and score-based. Merge names into
    # hard_avoids so the existing MUST AVOID block covers them, and pull
    # allergies into their own list for prompt emphasis.
    catalog_avoid_names: list[str] = []
    allergy_names: list[str] = []
    for pref in list_ingredient_preferences(session, user_id):
        if not pref.active:
            continue
        if pref.choice_mode not in {"avoid", "allergy"}:
            continue
        ingredient_name = pref.base_ingredient.name if pref.base_ingredient else ""
        if not ingredient_name:
            continue
        if pref.choice_mode == "allergy":
            allergy_names.append(ingredient_name)
        else:
            catalog_avoid_names.append(ingredient_name)

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

    goal_row = get_dietary_goal(session, user_id)
    dietary_goal = None
    if goal_row is not None:
        dietary_goal = DietaryGoalContext(
            goal_type=goal_row.goal_type,
            daily_calories=goal_row.daily_calories,
            protein_g=goal_row.protein_g,
            carbs_g=goal_row.carbs_g,
            fat_g=goal_row.fat_g,
            fiber_g=goal_row.fiber_g,
            notes=goal_row.notes or "",
        )

    # Dedupe against PreferenceSignal-derived hard_avoids. Allergies are
    # merged into hard_avoids as well so defense-in-depth is preserved even
    # if the prompt's separate "allergy" line is ignored.
    merged_avoids = list(dict.fromkeys(
        [*summary["hard_avoids"], *catalog_avoid_names, *allergy_names]
    ))
    deduped_allergies = list(dict.fromkeys(allergy_names))

    # Household-scoped term aliases (M26 Phase 3). Falls back to user_id
    # when called from a code path that hasn't threaded household_id
    # through yet — single-member households use user_id == household_id.
    from app.services.aliases import aliases_map

    alias_household_id = household_id or user_id
    aliases = aliases_map(session, household_id=alias_household_id)

    return PlanningContext(
        hard_avoids=merged_avoids,
        strong_likes=summary["strong_likes"],
        liked_cuisines=liked_cuisines,
        disliked_cuisines=disliked_cuisines,
        brands=summary["brands"],
        staples=pantry,
        recent_meals=recent_meal_names[:60],
        rules=summary["rules"],
        dietary_goal=dietary_goal,
        allergies=deduped_allergies,
        term_aliases=aliases,
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

        # Household shorthand dictionary (M26 Phase 3). Top of the
        # context block so the AI sees alias expansions BEFORE it
        # interprets the user's prompt — "chx" should already mean
        # "chicken" by the time it reaches the meal-planning request.
        if context.term_aliases:
            alias_lines = [
                f"- {term} → {expansion}"
                for term, expansion in sorted(context.term_aliases.items())
            ]
            sections.append(
                "Household shorthand (treat each term as if the user typed the expansion):\n"
                + "\n".join(alias_lines)
            )

        # Preference signals
        pref_lines: list[str] = []
        if context.allergies:
            # Allergies get their own line above the generic hard_avoids so
            # the AI treats them as hard constraints, not just preferences.
            pref_lines.append(
                "- HARD ALLERGIES — NEVER include these or any dish containing them: "
                + ", ".join(context.allergies)
            )
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

        # Dietary goal
        if context.dietary_goal and context.dietary_goal.daily_calories > 0:
            g = context.dietary_goal
            goal_lines = [
                f"- Daily target: {g.daily_calories} calories,"
                f" {g.protein_g}g protein, {g.carbs_g}g carbs, {g.fat_g}g fat"
                + (f", {g.fiber_g}g fiber" if g.fiber_g else ""),
                f"- Goal type: {g.goal_type}",
            ]
            if g.notes.strip():
                goal_lines.append(f"- Notes: {g.notes.strip()}")
            sections.append("Dietary goal (per-person, per-day):\n" + "\n".join(goal_lines))

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
        if context.dietary_goal and context.dietary_goal.daily_calories > 0:
            extra_lines.append(
                "- Design each day so the three meals together land within ±10% of the daily calorie target"
            )
            extra_lines.append(
                "- Prioritize recipes that help hit the protein target (especially at dinner)"
            )
        if extra_lines:
            extra_rules = "\n" + "\n".join(extra_lines)

    dates = [(week_start + timedelta(days=i)) for i in range(7)]
    day_labels = [f"{DAYS[i]} ({dates[i].isoformat()})" for i in range(7)]

    units_directive = unit_system_directive(user_settings)

    return f"""You are SimmerSmith, an AI meal planning assistant.

{units_directive}

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

    macro_flags = score_macro_drift(session, plan, user_id)

    return {
        "meal_scores": meal_scores,
        "plan_total_score": total,
        "blocked_meals": blocked,
        "macro_flags": macro_flags,
    }


def score_macro_drift(
    session: Session, plan: dict, user_id: str,
) -> list[dict]:
    """Score the generated plan against the user's daily calorie target.

    Returns a list of `{day_name, meal_date, calories, target, drift_pct}`
    entries for each day that drifts more than ±15% from the target. When
    there is no goal, no catalog macros, or no ingredients to match, returns
    an empty list — absence of flags does NOT mean the plan is on-target.
    """
    from app.services.nutrition import calculate_meal_macros
    from app.services.profile import get_dietary_goal

    goal = get_dietary_goal(session, user_id)
    if goal is None or goal.daily_calories <= 0:
        return []

    daily_calories: dict[str, float] = {}
    daily_day_name: dict[str, str] = {}
    for meal in plan.get("meal_plan", []):
        day_key = str(meal.get("meal_date") or "")
        if not day_key:
            continue
        ingredients = meal.get("ingredients") or []
        macros = calculate_meal_macros(session, ingredients)
        if macros.is_empty:
            continue
        daily_calories[day_key] = daily_calories.get(day_key, 0.0) + macros.calories
        daily_day_name.setdefault(day_key, str(meal.get("day_name") or ""))

    target = float(goal.daily_calories)
    flags: list[dict] = []
    for day_key, calories in sorted(daily_calories.items()):
        drift = (calories - target) / target if target > 0 else 0.0
        if abs(drift) >= 0.15:
            flags.append({
                "day_name": daily_day_name.get(day_key, ""),
                "meal_date": day_key,
                "calories": round(calories, 1),
                "target": int(target),
                "drift_pct": round(drift * 100, 1),
            })
    return flags


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


def rebalance_day(
    *,
    settings: Settings,
    user_settings: dict[str, str],
    week_start: date,
    target_date: date,
    day_name: str,
    planning_context: PlanningContext | None = None,
    existing_deficit_note: str = "",
) -> dict:
    """Generate fresh meals for a single day that hit the user's dietary goal.

    Returns a draft shaped like `generate_week_plan`: a `recipes` list and a
    `meal_plan` list containing only the rebuilt day's meals. Callers are
    responsible for deleting the day's existing meals before applying the
    draft.
    """
    base_prompt = _build_system_prompt(user_settings, week_start, context=planning_context)

    user_prompt = (
        f"Replan only {day_name} ({target_date.isoformat()}) with three meals "
        "(breakfast, lunch, dinner) that land within ±5% of the daily calorie "
        "target and respect every rule already stated in the system prompt. "
        f"Return a JSON object with `recipes` for the new meals and a "
        f"`meal_plan` array containing exactly 3 entries, all for "
        f"meal_date \"{target_date.isoformat()}\" and day_name \"{day_name}\"."
    )
    if existing_deficit_note:
        user_prompt += f" {existing_deficit_note}"

    raw = _call_ai_provider(
        settings=settings,
        user_settings=user_settings,
        system_prompt=base_prompt,
        user_prompt=user_prompt,
    )
    try:
        plan = _extract_json(raw)
    except json.JSONDecodeError as exc:
        logger.error("AI returned invalid JSON for day rebalance: %s", raw[:500])
        raise RuntimeError("AI returned an invalid meal plan. Please try again.") from exc

    recipes = plan.get("recipes", [])
    meal_plan = plan.get("meal_plan", [])

    for recipe in recipes:
        recipe.setdefault("ingredients", [])
        recipe.setdefault("steps", [])
        recipe.setdefault("meal_type", "")
        recipe.setdefault("cuisine", "")
        recipe.setdefault("servings", None)
        recipe.setdefault("prep_minutes", None)
        recipe.setdefault("cook_minutes", None)

    for meal in meal_plan:
        meal.setdefault("source", "ai")
        meal.setdefault("approved", False)
        meal.setdefault("notes", "")
        meal.setdefault("ingredients", [])
        meal.setdefault("meal_date", target_date.isoformat())
        meal.setdefault("day_name", day_name)

    return {
        "prompt": user_prompt,
        "model": "week-planner-rebalance",
        "recipes": recipes,
        "meal_plan": meal_plan,
        "week_notes": "",
    }
