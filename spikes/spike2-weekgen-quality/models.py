"""Provider-agnostic data shapes for the Spike 2 week-gen quality harness.

Mirrors the production planning context (app/services/week_planner.py:78
`gather_planning_context` → `PlanningContext`) and the generated-plan shape
consumed by `score_generated_plan` (week_planner.py:485). Kept minimal — only
the fields the rubric reads.

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class DietaryGoal:
    goal_type: str = ""          # e.g. "weight_loss", "muscle_gain", "maintain"
    daily_calories: int = 0
    protein_g: int = 0
    carbs_g: int = 0
    fat_g: int = 0
    fiber_g: int = 0
    notes: str = ""


@dataclass(frozen=True)
class PlanningContext:
    """The signal bundle fed into the week-gen prompt. Field names track
    `PlanningContext` in week_planner.py."""
    label: str                                   # corpus id (not sent to the model)
    hard_avoids: list[str] = field(default_factory=list)
    strong_likes: list[str] = field(default_factory=list)
    liked_cuisines: list[str] = field(default_factory=list)
    disliked_cuisines: list[str] = field(default_factory=list)
    staples: list[str] = field(default_factory=list)
    recent_meals: list[str] = field(default_factory=list)
    rules: list[str] = field(default_factory=list)
    allergies: list[str] = field(default_factory=list)
    dietary_goal: DietaryGoal | None = None


@dataclass(frozen=True)
class Recipe:
    name: str
    cuisine: str = ""
    meal_type: str = ""                          # breakfast / lunch / dinner
    ingredient_names: list[str] = field(default_factory=list)
    calories: float | None = None                # model self-reported (per serving)


@dataclass(frozen=True)
class Meal:
    day_name: str
    meal_date: str
    recipe_name: str


@dataclass(frozen=True)
class WeekPlan:
    """A generated plan. `meal_plan` is the 21-slot schedule; `recipes` are the
    distinct recipes it references (mirrors the production plan dict)."""
    recipes: list[Recipe] = field(default_factory=list)
    meal_plan: list[Meal] = field(default_factory=list)

    def recipe(self, name: str) -> Recipe | None:
        key = name.strip().lower()
        for r in self.recipes:
            if r.name.strip().lower() == key:
                return r
        return None
