"""The 8-context test corpus for Spike 2 — the durable input set.

Spans: two+ dietary goals, ≥2 allergy sets, varied preference signals, and
non-empty history (to stress reuse-cap + dedup). Provider-agnostic; the same
corpus feeds gpt-5.5, Claude, AFM 3, and PCC at iOS 27 GA.

THROWAWAY spike. See .docs/ai/phases/cloudkit-migration-spikes-spec.md.
"""
from __future__ import annotations

from models import DietaryGoal, PlanningContext

CORPUS: list[PlanningContext] = [
    PlanningContext(
        label="01-family-baseline",
        strong_likes=["chicken", "pasta", "roasted vegetables"],
        liked_cuisines=["Italian", "American"],
        staples=["olive oil", "garlic", "rice", "eggs"],
        rules=["weeknight dinners under 40 minutes"],
    ),
    PlanningContext(
        label="02-weight-loss",
        dietary_goal=DietaryGoal(goal_type="weight_loss", daily_calories=1500, protein_g=120, notes="high-volume, filling"),
        disliked_cuisines=["fried"],
        strong_likes=["salads", "grilled fish", "lentils"],
        staples=["spinach", "greek yogurt", "quinoa"],
    ),
    PlanningContext(
        label="03-muscle-gain-highprotein",
        dietary_goal=DietaryGoal(goal_type="muscle_gain", daily_calories=2600, protein_g=180, carbs_g=280, fat_g=80),
        strong_likes=["steak", "chicken thighs", "rice bowls"],
        liked_cuisines=["Korean", "Mexican"],
        staples=["rice", "black beans", "eggs", "oats"],
    ),
    PlanningContext(
        label="04-nut-allergy",
        allergies=["peanut", "almond", "cashew"],
        strong_likes=["stir fry", "noodles"],
        liked_cuisines=["Thai", "Chinese"],
        recent_meals=["Pad Thai", "Kung Pao Chicken", "Beef Lo Mein"],
        rules=["no peanut sauces — severe allergy"],
    ),
    PlanningContext(
        label="05-shellfish-dairy-allergy",
        allergies=["shrimp", "crab", "lobster", "milk", "cheese", "butter"],
        hard_avoids=["cilantro"],
        strong_likes=["roasted chicken", "grain bowls"],
        liked_cuisines=["Mediterranean", "Greek"],
        recent_meals=["Greek Chicken Bowls", "Falafel Wraps"],
    ),
    PlanningContext(
        label="06-vegetarian",
        hard_avoids=["chicken", "beef", "pork", "fish", "shrimp"],
        strong_likes=["paneer", "chickpeas", "tofu"],
        liked_cuisines=["Indian", "Mediterranean"],
        staples=["lentils", "rice", "canned tomatoes"],
        rules=["vegetarian household"],
    ),
    PlanningContext(
        label="07-kid-friendly-picky",
        hard_avoids=["mushrooms", "olives", "blue cheese"],
        strong_likes=["mac and cheese", "tacos", "meatballs"],
        liked_cuisines=["American", "Mexican"],
        staples=["pasta", "ground beef", "tortillas", "cheddar"],
        rules=["2 adults, 2 kids (6, 9) — mild flavors", "nothing too spicy"],
    ),
    PlanningContext(
        label="08-budget-history-heavy",
        strong_likes=["sheet-pan dinners", "soups", "rice and beans"],
        liked_cuisines=["American", "Tex-Mex"],
        staples=["rice", "dried beans", "frozen vegetables", "eggs"],
        rules=["tight grocery budget", "minimize food waste"],
        recent_meals=[
            "Sheet-Pan Sausage and Peppers", "Chicken Tortilla Soup",
            "Red Beans and Rice", "Black Bean Tacos", "Tuna Pasta Bake",
            "Lentil Soup", "Egg Fried Rice", "Chili",
        ],
    ),
]

assert len(CORPUS) == 8
assert any(c.dietary_goal for c in CORPUS), "need at least one goal"
assert sum(1 for c in CORPUS if c.allergies) >= 2, "need ≥2 allergy sets"
