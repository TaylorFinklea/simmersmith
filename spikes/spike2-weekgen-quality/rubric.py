"""The week-gen quality rubric — the durable, tested core of Spike 2.

Pure functions over a `WeekPlan` + `PlanningContext`. No providers, no network.
Mirrors the production checks where they exist: allergy/avoid blocking
(score_meal_candidate), reuse cap (≤3/recipe/week), and ±15% macro drift
(score_macro_drift, week_planner.py:530).

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from models import PlanningContext, WeekPlan

REUSE_CAP = 3            # max uses per recipe per week (existing guardrail)
MACRO_DRIFT_TOLERANCE = 0.15   # ±15%, matches score_macro_drift


@dataclass
class Scorecard:
    label: str
    # hard fail
    allergy_violations: list[tuple[str, str]] = field(default_factory=list)  # (recipe, allergen)
    # soft criteria
    avoid_hits: list[tuple[str, str]] = field(default_factory=list)          # (recipe, avoided term)
    reuse_violations: list[tuple[str, int]] = field(default_factory=list)    # (recipe, count)
    history_repeats: list[str] = field(default_factory=list)
    distinct_cuisines: int = 0
    macro_drift_days: list[tuple[str, float]] = field(default_factory=list)  # (day, drift_pct)
    meal_count: int = 0
    latency_seconds: float | None = None

    @property
    def passed(self) -> bool:
        """A plan PASSES only with zero allergy violations — the one hard gate."""
        return not self.allergy_violations


def _matches(term: str, ingredient_names: list[str]) -> bool:
    t = term.strip().lower()
    if not t:
        return False
    return any(t in name.strip().lower() for name in ingredient_names)


def score(plan: WeekPlan, context: PlanningContext, *, latency_seconds: float | None = None) -> Scorecard:
    card = Scorecard(label=context.label, meal_count=len(plan.meal_plan), latency_seconds=latency_seconds)

    # --- allergy violations (HARD FAIL) + avoid hits (soft) ---
    for meal in plan.meal_plan:
        recipe = plan.recipe(meal.recipe_name)
        if recipe is None:
            continue
        for allergen in context.allergies:
            if _matches(allergen, recipe.ingredient_names):
                card.allergy_violations.append((recipe.name, allergen))
        for avoided in context.hard_avoids:
            if _matches(avoided, recipe.ingredient_names):
                card.avoid_hits.append((recipe.name, avoided))

    # --- reuse cap (≤3 per recipe per week) ---
    counts = Counter(m.recipe_name.strip().lower() for m in plan.meal_plan)
    for name, n in counts.items():
        if n > REUSE_CAP:
            card.reuse_violations.append((name, n))

    # --- history dedup ---
    recent = {m.strip().lower() for m in context.recent_meals}
    seen: set[str] = set()
    for meal in plan.meal_plan:
        key = meal.recipe_name.strip().lower()
        if key in recent and key not in seen:
            seen.add(key)
            card.history_repeats.append(meal.recipe_name)

    # --- variety (distinct cuisines across the week) ---
    cuisines: set[str] = set()
    for meal in plan.meal_plan:
        recipe = plan.recipe(meal.recipe_name)
        if recipe is None:
            continue
        cuisine = (recipe.cuisine or "").strip().lower()
        if cuisine:
            cuisines.add(cuisine)
    card.distinct_cuisines = len(cuisines)

    # --- macro drift (per-day calories vs goal, ±15%) ---
    goal = context.dietary_goal
    if goal is not None and goal.daily_calories > 0:
        target = float(goal.daily_calories)
        by_day: dict[str, float] = {}
        any_macros = False
        for meal in plan.meal_plan:
            recipe = plan.recipe(meal.recipe_name)
            if recipe is None or recipe.calories is None:
                continue
            any_macros = True
            by_day[meal.day_name] = by_day.get(meal.day_name, 0.0) + recipe.calories
        if any_macros:
            for day, kcal in sorted(by_day.items()):
                drift = (kcal - target) / target
                if abs(drift) >= MACRO_DRIFT_TOLERANCE:
                    card.macro_drift_days.append((day, round(drift * 100, 1)))

    return card


def format_table(cards: list[Scorecard]) -> str:
    """Compact per-backend comparison table for the report."""
    rows = ["| plan | pass | allergy | avoid | reuse | repeats | cuisines | macro-drift days | latency |",
            "|---|---|---|---|---|---|---|---|---|"]
    for c in cards:
        rows.append(
            f"| {c.label} | {'✓' if c.passed else '✗'} | {len(c.allergy_violations)} "
            f"| {len(c.avoid_hits)} | {len(c.reuse_violations)} | {len(c.history_repeats)} "
            f"| {c.distinct_cuisines} | {len(c.macro_drift_days)} "
            f"| {f'{c.latency_seconds:.1f}s' if c.latency_seconds is not None else '—'} |"
        )
    return "\n".join(rows)
