"""Backend adapters — STUBS to be wired at iOS 27 GA.

Each backend turns a `PlanningContext` into a `(WeekPlan, latency_seconds)`.
The cloud backends (gpt-5.5, Claude) are runnable today; the on-device ones
(AFM 3, PCC) need iOS 27 + the Foundation Models framework and run via a
separate Swift tool that emits plan JSON this harness ingests.

Per the 2026-06-15 decision the whole run is deferred to iOS 27 GA, so these
are intentionally not invoked yet — the durable, tested deliverable now is the
corpus + rubric.

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
from __future__ import annotations

import json
from typing import Protocol

from models import Meal, PlanningContext, Recipe, WeekPlan

# The real prompt to lift at GA. Do NOT duplicate it here — read it from source
# so the spike measures the production prompt, not a paraphrase.
PROMPT_SOURCE = "app/services/week_planner.py::_build_system_prompt (+ gather_planning_context)"


class Backend(Protocol):
    name: str
    def generate(self, context: PlanningContext) -> tuple[WeekPlan, float]:
        """Return (plan, latency_seconds). Raises if not yet wired."""
        ...


class _Pending:
    """Base for not-yet-wired backends. Documents what GA wiring needs."""
    name = "pending"
    ga_note = ""

    def generate(self, context: PlanningContext) -> tuple[WeekPlan, float]:
        raise NotImplementedError(
            f"{self.name}: wire at iOS 27 GA. {self.ga_note} "
            f"Lift the prompt from {PROMPT_SOURCE}."
        )


class OpenAIBackend(_Pending):
    """gpt-5.5 cloud baseline. At GA: call the existing provider path
    (run_direct_provider / the week-gen route) with the lifted prompt."""
    name = "gpt-5.5"
    ga_note = "Reuse app provider client + SIMMERSMITH_AI_OPENAI_API_KEY."


class AnthropicBackend(_Pending):
    """Claude cloud baseline (the realistic BYO-key/credits upgrade tier)."""
    name = "claude"
    ga_note = "Anthropic Messages API + the lifted prompt; structured JSON out."


class AFM3OnDeviceBackend(_Pending):
    """Apple Foundation Models, on-device 20B sparse. iOS 27 only."""
    name = "afm3-on-device"
    ga_note = "Swift tool using FoundationModels @Generable for the 21-meal schema; emit plan JSON."


class PCCBackend(_Pending):
    """Apple Private Cloud Compute tier (free under Small Business Program)."""
    name = "pcc"
    ga_note = "Same Swift call site, PCC tier; emit plan JSON."


def plan_from_json(payload: str | dict) -> WeekPlan:
    """Ingest a plan emitted by any backend (cloud JSON or the Swift on-device
    tool's output) into the rubric's `WeekPlan`. Tolerant of the production
    plan dict shape (recipes[].ingredients[].ingredient_name + meal_plan[])."""
    data = json.loads(payload) if isinstance(payload, str) else payload

    recipes: list[Recipe] = []
    for r in data.get("recipes", []):
        ings = r.get("ingredients", [])
        names = [
            (i.get("ingredient_name") if isinstance(i, dict) else str(i)) or ""
            for i in ings
        ]
        recipes.append(Recipe(
            name=r.get("name", ""),
            cuisine=r.get("cuisine", ""),
            meal_type=r.get("meal_type", ""),
            ingredient_names=[n for n in names if n],
            calories=r.get("calories"),
        ))

    meals: list[Meal] = []
    for m in data.get("meal_plan", []):
        meals.append(Meal(
            day_name=m.get("day_name", ""),
            meal_date=m.get("meal_date", ""),
            recipe_name=m.get("recipe_name", ""),
        ))

    return WeekPlan(recipes=recipes, meal_plan=meals)


CLOUD_BACKENDS: list[Backend] = [OpenAIBackend(), AnthropicBackend()]
ONDEVICE_BACKENDS: list[Backend] = [AFM3OnDeviceBackend(), PCCBackend()]
