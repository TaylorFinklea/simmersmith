"""Rubric tests — the verifiable-now core of Spike 2. Run: python3 -m unittest test_rubric

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
import unittest

from backends import plan_from_json
from corpus import CORPUS
from models import DietaryGoal, Meal, PlanningContext, Recipe, WeekPlan
from rubric import score


def plan(*recipes: Recipe, schedule: list[tuple[str, str]] | None = None) -> WeekPlan:
    """Build a WeekPlan; schedule is [(day_name, recipe_name)], defaults to one
    meal per recipe across distinct days."""
    if schedule is None:
        days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        schedule = [(days[i % 7], r.name) for i, r in enumerate(recipes)]
    meals = [Meal(day_name=d, meal_date=f"2026-06-{15 + i}", recipe_name=n)
             for i, (d, n) in enumerate(schedule)]
    return WeekPlan(recipes=list(recipes), meal_plan=meals)


class AllergyTests(unittest.TestCase):
    def test_allergen_in_ingredients_is_hard_fail(self):
        ctx = PlanningContext(label="t", allergies=["peanut"])
        p = plan(Recipe(name="Pad Thai", ingredient_names=["rice noodles", "peanut sauce", "tofu"]))
        card = score(p, ctx)
        self.assertFalse(card.passed)
        self.assertEqual(card.allergy_violations, [("Pad Thai", "peanut")])

    def test_substring_match_catches_cheese_under_dairy(self):
        ctx = PlanningContext(label="t", allergies=["cheese"])
        p = plan(Recipe(name="Mac and Cheese", ingredient_names=["pasta", "cheddar cheese", "milk"]))
        self.assertFalse(score(p, ctx).passed)

    def test_clean_plan_passes(self):
        ctx = PlanningContext(label="t", allergies=["shrimp"])
        p = plan(Recipe(name="Roast Chicken", ingredient_names=["chicken", "thyme", "potatoes"]))
        card = score(p, ctx)
        self.assertTrue(card.passed)
        self.assertEqual(card.allergy_violations, [])


class AvoidTests(unittest.TestCase):
    def test_avoid_is_soft_not_hard_fail(self):
        ctx = PlanningContext(label="t", hard_avoids=["mushrooms"])
        p = plan(Recipe(name="Risotto", ingredient_names=["arborio rice", "mushrooms"]))
        card = score(p, ctx)
        self.assertTrue(card.passed)                       # avoids don't fail the gate
        self.assertEqual(card.avoid_hits, [("Risotto", "mushrooms")])


class ReuseTests(unittest.TestCase):
    def test_over_cap_flagged(self):
        ctx = PlanningContext(label="t")
        r = Recipe(name="Tacos", ingredient_names=["tortilla"])
        sched = [("Mon", "Tacos"), ("Tue", "Tacos"), ("Wed", "Tacos"), ("Thu", "Tacos")]
        card = score(plan(r, schedule=sched), ctx)
        self.assertEqual(card.reuse_violations, [("tacos", 4)])

    def test_at_cap_ok(self):
        ctx = PlanningContext(label="t")
        r = Recipe(name="Tacos", ingredient_names=["tortilla"])
        sched = [("Mon", "Tacos"), ("Tue", "Tacos"), ("Wed", "Tacos")]
        self.assertEqual(score(plan(r, schedule=sched), ctx).reuse_violations, [])


class HistoryTests(unittest.TestCase):
    def test_repeat_of_recent_meal_flagged(self):
        ctx = PlanningContext(label="t", recent_meals=["Chili", "Lentil Soup"])
        p = plan(Recipe(name="Chili", ingredient_names=["beans"]),
                 Recipe(name="Roast Chicken", ingredient_names=["chicken"]))
        self.assertEqual(score(p, ctx).history_repeats, ["Chili"])


class MacroTests(unittest.TestCase):
    def test_day_over_target_flagged(self):
        ctx = PlanningContext(label="t", dietary_goal=DietaryGoal(goal_type="weight_loss", daily_calories=1500))
        # one day, 2200 kcal → +46.7% drift, well past ±15%
        p = WeekPlan(
            recipes=[Recipe(name="Big Dinner", calories=2200.0, ingredient_names=["x"])],
            meal_plan=[Meal(day_name="Mon", meal_date="2026-06-15", recipe_name="Big Dinner")],
        )
        card = score(p, ctx)
        self.assertEqual(len(card.macro_drift_days), 1)
        self.assertEqual(card.macro_drift_days[0][0], "Mon")

    def test_on_target_not_flagged(self):
        ctx = PlanningContext(label="t", dietary_goal=DietaryGoal(goal_type="maintain", daily_calories=2000))
        p = WeekPlan(
            recipes=[Recipe(name="Balanced", calories=2050.0, ingredient_names=["x"])],
            meal_plan=[Meal(day_name="Mon", meal_date="2026-06-15", recipe_name="Balanced")],
        )
        self.assertEqual(score(p, ctx).macro_drift_days, [])

    def test_no_macros_means_unscored_not_passing(self):
        ctx = PlanningContext(label="t", dietary_goal=DietaryGoal(goal_type="maintain", daily_calories=2000))
        p = plan(Recipe(name="No Calories Reported", ingredient_names=["x"]))  # calories=None
        self.assertEqual(score(p, ctx).macro_drift_days, [])  # absence of flags ≠ on-target


class VarietyTests(unittest.TestCase):
    def test_distinct_cuisines_counted(self):
        ctx = PlanningContext(label="t")
        p = plan(Recipe(name="A", cuisine="Italian"), Recipe(name="B", cuisine="Thai"),
                 Recipe(name="C", cuisine="Italian"))
        self.assertEqual(score(p, ctx).distinct_cuisines, 2)


class IngestTests(unittest.TestCase):
    def test_plan_from_production_shape(self):
        payload = {
            "recipes": [{"name": "Stir Fry", "cuisine": "Chinese", "meal_type": "dinner",
                         "ingredients": [{"ingredient_name": "broccoli"}, {"ingredient_name": "peanut"}]}],
            "meal_plan": [{"day_name": "Mon", "meal_date": "2026-06-15", "recipe_name": "Stir Fry"}],
        }
        p = plan_from_json(payload)
        ctx = PlanningContext(label="t", allergies=["peanut"])
        self.assertFalse(score(p, ctx).passed)


class CorpusTests(unittest.TestCase):
    def test_corpus_well_formed(self):
        self.assertEqual(len(CORPUS), 8)
        self.assertGreaterEqual(sum(1 for c in CORPUS if c.allergies), 2)
        self.assertTrue(any(c.dietary_goal for c in CORPUS))
        self.assertEqual(len({c.label for c in CORPUS}), 8)  # unique labels


if __name__ == "__main__":
    unittest.main()
