"""Tests for AI week planner context enrichment, guardrails, and scoring."""
from __future__ import annotations

from datetime import date

from app.services.week_planner import (
    PlanningContext,
    _build_system_prompt,
    validate_plan_guardrails,
)

TEST_USER_ID = "00000000-0000-0000-0000-000000000001"


# ---------------------------------------------------------------------------
# _build_system_prompt
# ---------------------------------------------------------------------------

def test_prompt_without_context_matches_original_shape() -> None:
    """Empty context produces the same prompt structure as before."""
    prompt = _build_system_prompt(
        user_settings={"household_name": "Test Family", "dietary_constraints": "none"},
        week_start=date(2026, 4, 21),
    )
    assert "User profile:" in prompt
    assert "Household Name: Test Family" in prompt
    assert "Rules:" in prompt
    # No preference or history sections
    assert "Preference signals:" not in prompt
    assert "Pantry staples" not in prompt
    assert "Recent meals" not in prompt


def test_prompt_with_empty_context_matches_original() -> None:
    """Passing an empty PlanningContext should not add extra sections."""
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=PlanningContext(),
    )
    assert "Preference signals:" not in prompt
    assert "Pantry staples" not in prompt
    assert "Recent meals" not in prompt
    # Still has the dedup rule even with empty context
    assert "at most 3 times" in prompt


def test_prompt_includes_hard_avoids() -> None:
    ctx = PlanningContext(hard_avoids=["shellfish", "peanuts"])
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "MUST AVOID: shellfish, peanuts" in prompt
    assert "NEVER include ingredients from the MUST AVOID list" in prompt


def test_prompt_separates_allergies_from_avoids() -> None:
    """Allergies should render on their own emphasized line above the
    generic MUST AVOID list. Prevents the AI from treating a hard allergy
    as just another dislike."""
    ctx = PlanningContext(
        hard_avoids=["peanuts", "cilantro"],
        allergies=["peanuts"],
    )
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    allergy_idx = prompt.find("HARD ALLERGIES")
    avoid_idx = prompt.find("MUST AVOID:")
    assert allergy_idx != -1, "Allergy line should be rendered"
    assert avoid_idx != -1, "MUST AVOID line should still be present"
    assert allergy_idx < avoid_idx, "Allergies should come before MUST AVOID"
    assert "peanuts" in prompt[allergy_idx:avoid_idx]


def test_prompt_includes_strong_likes_and_cuisines() -> None:
    ctx = PlanningContext(
        strong_likes=["Chicken Shawarma", "Tacos"],
        liked_cuisines=["Mexican", "Middle Eastern"],
        disliked_cuisines=["French"],
    )
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "Strongly likes: Chicken Shawarma, Tacos" in prompt
    assert "Liked cuisines: Mexican, Middle Eastern" in prompt
    assert "Disliked cuisines: French" in prompt
    assert "Favor ingredients and cuisines" in prompt
    assert "Avoid cuisines the household dislikes" in prompt


def test_prompt_includes_staples() -> None:
    ctx = PlanningContext(staples=["olive oil", "rice", "salt"])
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "Pantry staples (always available, use freely):" in prompt
    assert "olive oil, rice, salt" in prompt
    assert "Leverage pantry staples" in prompt


def test_prompt_includes_recent_meals() -> None:
    ctx = PlanningContext(recent_meals=["Spaghetti Bolognese", "Grilled Chicken"])
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "Recent meals (avoid repeating these for variety):" in prompt
    assert "Spaghetti Bolognese, Grilled Chicken" in prompt
    assert "Avoid repeating any meal" in prompt


def test_prompt_includes_brands() -> None:
    ctx = PlanningContext(brands=["Nature's Own", "Kerrygold"])
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "Preferred brands: Nature's Own, Kerrygold" in prompt


def test_prompt_with_full_context() -> None:
    """All sections present when context is fully populated."""
    ctx = PlanningContext(
        hard_avoids=["shellfish"],
        strong_likes=["Tacos"],
        liked_cuisines=["Mexican"],
        disliked_cuisines=["French"],
        brands=["Kerrygold"],
        staples=["olive oil"],
        recent_meals=["Pasta"],
        rules=["Household: 2 adults."],
    )
    prompt = _build_system_prompt(
        user_settings={"household_name": "Smith"},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "MUST AVOID: shellfish" in prompt
    assert "Strongly likes: Tacos" in prompt
    assert "Liked cuisines: Mexican" in prompt
    assert "Disliked cuisines: French" in prompt
    assert "Preferred brands: Kerrygold" in prompt
    assert "Pantry staples" in prompt
    assert "Recent meals" in prompt
    # Core rules still present
    assert "21 meals total" in prompt
    assert "valid JSON" in prompt


# ---------------------------------------------------------------------------
# validate_plan_guardrails
# ---------------------------------------------------------------------------

def _make_plan(recipe_names: list[str], ingredients: list[list[dict]] | None = None) -> dict:
    """Helper to build a minimal plan dict for guardrail testing."""
    recipes = []
    seen = set()
    for i, name in enumerate(recipe_names):
        if name not in seen:
            seen.add(name)
            ings = ingredients[i] if ingredients and i < len(ingredients) else []
            recipes.append({"name": name, "ingredients": ings})

    meal_plan = [{"recipe_name": name} for name in recipe_names]
    return {"recipes": recipes, "meal_plan": meal_plan}


def test_guardrails_pass_for_clean_plan() -> None:
    plan = _make_plan(["A", "B", "C", "D", "E", "F", "G"] * 3)
    warnings = validate_plan_guardrails(plan)
    assert warnings == []


def test_guardrails_catch_over_duplication() -> None:
    plan = _make_plan(["Tacos"] * 5 + ["Pasta"] * 16)
    warnings = validate_plan_guardrails(plan)
    assert any("Tacos" in w and "5 times" in w for w in warnings)
    assert any("Pasta" in w and "16 times" in w for w in warnings)


def test_guardrails_catch_recent_meal_repeat() -> None:
    ctx = PlanningContext(recent_meals=["Spaghetti Bolognese"])
    plan = _make_plan(["Spaghetti Bolognese", "New Dish", "Another Dish"] * 7)
    warnings = validate_plan_guardrails(plan, ctx)
    assert any("recently" in w.lower() and "Spaghetti Bolognese" in w for w in warnings)


def test_guardrails_catch_avoided_ingredient() -> None:
    ctx = PlanningContext(hard_avoids=["peanuts"])
    plan = _make_plan(
        ["Pad Thai"],
        ingredients=[[{"ingredient_name": "peanuts, crushed"}]],
    )
    warnings = validate_plan_guardrails(plan, ctx)
    assert any("peanuts" in w.lower() for w in warnings)


def test_guardrails_no_false_positive_on_clean_ingredients() -> None:
    ctx = PlanningContext(hard_avoids=["shellfish"])
    plan = _make_plan(
        ["Chicken Stir Fry"],
        ingredients=[[{"ingredient_name": "chicken breast"}, {"ingredient_name": "broccoli"}]],
    )
    warnings = validate_plan_guardrails(plan, ctx)
    assert not any("avoided" in w.lower() for w in warnings)


# ---------------------------------------------------------------------------
# gather_planning_context (integration — uses DB)
# ---------------------------------------------------------------------------

def test_gather_planning_context_with_preferences(client) -> None:
    """Context includes preference signals when set."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    # Set up preferences via API
    client.post("/api/preferences", json={
        "signals": [
            {"signal_type": "ingredient", "name": "Eggplant", "score": -5, "weight": 5},
            {"signal_type": "cuisine", "name": "Italian", "score": 4, "weight": 3},
            {"signal_type": "cuisine", "name": "French", "score": -3, "weight": 2},
            {"signal_type": "meal", "name": "Tacos", "score": 5, "weight": 4},
            {"signal_type": "brand", "name": "Kerrygold", "score": 3, "weight": 2},
        ]
    })

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    assert "Eggplant" in ctx.hard_avoids
    assert "Tacos" in ctx.strong_likes
    assert "Italian" in ctx.liked_cuisines
    assert "French" in ctx.disliked_cuisines
    assert "Kerrygold" in ctx.brands


def test_gather_planning_context_merges_ingredient_preference_avoids(client) -> None:
    """IngredientPreference rows with choice_mode=avoid/allergy feed into
    the planner's hard_avoids list. Allergies additionally land in
    `allergies` so the prompt emphasizes them."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    def _make_base(name: str) -> str:
        resp = client.post(
            "/api/ingredients",
            json={
                "name": name,
                "category": "Produce",
                "default_unit": "bunch",
                "nutrition_reference_amount": 1,
                "nutrition_reference_unit": "oz",
                "calories": 5,
            },
        )
        assert resp.status_code == 200, resp.text
        return resp.json()["base_ingredient_id"]

    cilantro_id = _make_base("Cilantro")
    peanut_id = _make_base("Peanuts")

    r1 = client.post(
        "/api/ingredient-preferences",
        json={"base_ingredient_id": cilantro_id, "choice_mode": "avoid"},
    )
    assert r1.status_code == 200, r1.text
    r2 = client.post(
        "/api/ingredient-preferences",
        json={"base_ingredient_id": peanut_id, "choice_mode": "allergy"},
    )
    assert r2.status_code == 200, r2.text

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    assert "Cilantro" in ctx.hard_avoids
    assert "Peanuts" in ctx.hard_avoids  # allergies merged into hard_avoids too
    assert ctx.allergies == ["Peanuts"]


def test_score_meal_candidate_blocks_meals_with_avoid_ingredients(client) -> None:
    """Post-generation scoring should flip blocked=True for a meal
    containing an IngredientPreference-flagged avoid ingredient, even
    without a PreferenceSignal entry."""
    from app.db import session_scope
    from app.schemas.preferences import MealScoreRequest
    from app.services.preferences import score_meal_candidate

    create = client.post(
        "/api/ingredients",
        json={
            "name": "Mushrooms",
            "category": "Produce",
            "default_unit": "oz",
            "nutrition_reference_amount": 1,
            "nutrition_reference_unit": "oz",
            "calories": 3,
        },
    )
    mushroom_id = create.json()["base_ingredient_id"]
    client.post(
        "/api/ingredient-preferences",
        json={"base_ingredient_id": mushroom_id, "choice_mode": "avoid"},
    )

    payload = MealScoreRequest(
        recipe_name="Mushroom Risotto",
        cuisine="Italian",
        ingredient_names=["arborio rice", "mushrooms", "parmesan"],
        tags=[],
    )
    with session_scope() as session:
        result = score_meal_candidate(session, TEST_USER_ID, payload)

    assert result["blocked"] is True
    assert any("Mushrooms" in b for b in result["blockers"])


def test_gather_planning_context_with_staples(client) -> None:
    """Context includes active staples."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    # Default seed includes staples like olive oil, salt, pepper
    assert len(ctx.staples) > 0
    assert "olive oil" in ctx.staples


def test_gather_planning_context_with_recent_meals(client) -> None:
    """Context includes meal names from recent weeks."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    # Create a week with meals
    week_resp = client.post("/api/weeks", json={"week_start": "2026-03-30", "notes": ""})
    week_id = week_resp.json()["week_id"]
    client.put(f"/api/weeks/{week_id}/meals", json=[
        {"day_name": "Monday", "meal_date": "2026-03-30", "slot": "dinner",
         "recipe_name": "Test Pasta", "servings": 4},
    ])

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    assert "Test Pasta" in ctx.recent_meals


def test_gather_planning_context_excludes_current_week(client) -> None:
    """The week being planned should not appear in recent meals."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    # Create two weeks
    week1 = client.post("/api/weeks", json={"week_start": "2026-03-23", "notes": ""}).json()
    week2 = client.post("/api/weeks", json={"week_start": "2026-03-30", "notes": ""}).json()

    client.put(f"/api/weeks/{week1['week_id']}/meals", json=[
        {"day_name": "Monday", "meal_date": "2026-03-23", "slot": "dinner",
         "recipe_name": "Old Meal", "servings": 4},
    ])
    client.put(f"/api/weeks/{week2['week_id']}/meals", json=[
        {"day_name": "Monday", "meal_date": "2026-03-30", "slot": "dinner",
         "recipe_name": "Current Meal", "servings": 4},
    ])

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID, exclude_week_id=week2["week_id"])

    assert "Old Meal" in ctx.recent_meals
    assert "Current Meal" not in ctx.recent_meals


def test_gather_planning_context_empty_for_new_user(client) -> None:
    """New user with no preferences/weeks gets empty context (graceful degradation)."""
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    assert ctx.hard_avoids == []
    assert ctx.strong_likes == []
    assert ctx.liked_cuisines == []
    assert ctx.disliked_cuisines == []
    assert ctx.brands == []
    assert ctx.recent_meals == []
    # Staples may have defaults from seed, but other fields are empty


# ---------------------------------------------------------------------------
# score_generated_plan (integration — uses DB)
# ---------------------------------------------------------------------------

def test_score_generated_plan_returns_scores(client) -> None:
    """Scoring a plan returns per-recipe scores and totals."""
    from app.db import session_scope
    from app.services.week_planner import score_generated_plan

    # Set up a preference to score against
    client.post("/api/preferences", json={
        "signals": [
            {"signal_type": "ingredient", "name": "Eggplant", "score": -5, "weight": 5},
        ]
    })

    plan = {
        "recipes": [
            {
                "name": "Eggplant Parmesan",
                "cuisine": "Italian",
                "meal_type": "dinner",
                "ingredients": [{"ingredient_name": "eggplant"}, {"ingredient_name": "mozzarella"}],
            },
            {
                "name": "Grilled Chicken",
                "cuisine": "American",
                "meal_type": "dinner",
                "ingredients": [{"ingredient_name": "chicken breast"}],
            },
        ],
        "meal_plan": [],
    }

    with session_scope() as session:
        scores = score_generated_plan(session, TEST_USER_ID, plan)

    assert len(scores["meal_scores"]) == 2
    assert isinstance(scores["plan_total_score"], int)
    # Eggplant Parmesan should be blocked due to eggplant avoidance
    assert "Eggplant Parmesan" in scores["blocked_meals"]
    assert "Grilled Chicken" not in scores["blocked_meals"]


# ---------------------------------------------------------------------------
# Dietary goal integration (M4)
# ---------------------------------------------------------------------------

def test_prompt_includes_dietary_goal_section() -> None:
    from app.services.week_planner import DietaryGoalContext

    ctx = PlanningContext(
        dietary_goal=DietaryGoalContext(
            goal_type="lose",
            daily_calories=1800,
            protein_g=180,
            carbs_g=135,
            fat_g=60,
            fiber_g=30,
            notes="Low sodium",
        )
    )
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=ctx,
    )
    assert "Dietary goal" in prompt
    assert "1800 calories" in prompt
    assert "180g protein" in prompt
    assert "30g fiber" in prompt
    assert "Low sodium" in prompt
    assert "±10%" in prompt


def test_prompt_without_dietary_goal_omits_section() -> None:
    prompt = _build_system_prompt(
        user_settings={},
        week_start=date(2026, 4, 21),
        context=PlanningContext(hard_avoids=["peanuts"]),
    )
    assert "Dietary goal" not in prompt
    assert "±10%" not in prompt


def test_dietary_goal_endpoint_roundtrip(client) -> None:
    # No goal on a fresh profile.
    response = client.get("/api/profile/dietary-goal")
    assert response.status_code == 200
    assert response.json() is None

    payload = {
        "goal_type": "maintain",
        "daily_calories": 2100,
        "protein_g": 150,
        "carbs_g": 240,
        "fat_g": 70,
        "fiber_g": 30,
        "notes": "Keep it balanced",
    }
    response = client.put("/api/profile/dietary-goal", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["daily_calories"] == 2100
    assert body["protein_g"] == 150
    assert body["notes"] == "Keep it balanced"

    # Profile now surfaces the goal too.
    profile = client.get("/api/profile").json()
    assert profile["dietary_goal"]["daily_calories"] == 2100

    # Delete clears it.
    response = client.delete("/api/profile/dietary-goal")
    assert response.status_code == 204
    assert client.get("/api/profile/dietary-goal").json() is None


def test_gather_planning_context_includes_goal(client) -> None:
    from app.db import session_scope
    from app.services.week_planner import gather_planning_context

    client.put("/api/profile/dietary-goal", json={
        "goal_type": "gain",
        "daily_calories": 2800,
        "protein_g": 200,
        "carbs_g": 320,
        "fat_g": 90,
        "fiber_g": 35,
        "notes": "",
    })

    with session_scope() as session:
        ctx = gather_planning_context(session, TEST_USER_ID)

    assert ctx.dietary_goal is not None
    assert ctx.dietary_goal.daily_calories == 2800
    assert ctx.dietary_goal.goal_type == "gain"


def test_dietary_goal_rejects_out_of_range_calories(client) -> None:
    response = client.put("/api/profile/dietary-goal", json={
        "goal_type": "lose",
        "daily_calories": 100,  # well under the 800 minimum
        "protein_g": 100,
        "carbs_g": 100,
        "fat_g": 50,
    })
    assert response.status_code == 422


def test_preset_macros_splits_calories() -> None:
    from app.services.profile import preset_macros

    protein, carbs, fat = preset_macros("maintain", 2000)
    # Calories from macros should be within 5 of the target (rounding).
    assert abs((protein * 4 + carbs * 4 + fat * 9) - 2000) <= 5
    lose_p, _, _ = preset_macros("lose", 1800)
    # "Lose" preset biases toward protein.
    assert lose_p > protein * (1800 / 2000)


def test_macro_flags_empty_without_goal(client) -> None:
    """With no goal set, macro_flags is empty regardless of plan content."""
    from app.db import session_scope
    from app.services.week_planner import score_generated_plan

    plan = {
        "recipes": [],
        "meal_plan": [
            {
                "day_name": "Monday",
                "meal_date": "2026-04-13",
                "slot": "breakfast",
                "ingredients": [{"ingredient_name": "oats", "quantity": 100, "unit": "g"}],
            }
        ],
    }
    with session_scope() as session:
        scores = score_generated_plan(session, TEST_USER_ID, plan)

    assert scores["macro_flags"] == []
