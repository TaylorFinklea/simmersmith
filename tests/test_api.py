from __future__ import annotations

import json
from datetime import UTC, datetime

from app.api.assistant import encode_sse
from app.services.assistant_ai import AssistantExecutionTarget, AssistantProviderEnvelope, AssistantTurnResult
from app.services.assistant_ai import strict_json_schema
from app.services import recipe_import


def test_root_route_serves_html_shell(client) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert '<div id="root"></div>' in response.text

    missing_api_response = client.get("/api/does-not-exist")
    assert missing_api_response.status_code == 404


def test_profile_defaults_are_available(client) -> None:
    response = client.get("/api/profile")
    assert response.status_code == 200
    payload = response.json()
    assert payload["updated_at"] is not None
    assert payload["settings"]["week_start_day"] == "Monday"
    assert payload["secret_flags"]["ai_direct_api_key_present"] is False
    assert any(staple["normalized_name"] == "olive oil" for staple in payload["staples"])


def test_health_route_reports_ai_capabilities(client) -> None:
    response = client.get("/api/health")
    assert response.status_code == 200
    payload = response.json()
    assert payload["status"] == "ok"
    assert payload["ai_capabilities"]["supports_user_override"] is True
    assert any(provider["provider_id"] == "mcp" for provider in payload["ai_capabilities"]["available_providers"])


def test_preference_memory_round_trip_and_scoring(client) -> None:
    profile_update = {
        "settings": {
            "household_adults": "2",
            "household_kids": "3",
            "monthly_grocery_budget_usd": "800",
            "food_principles": "Prefer whole foods and avoid highly processed meals when possible.",
            "portable_lunch_days": "Monday, Friday, Saturday",
        }
    }
    profile_response = client.put("/api/profile", json=profile_update)
    assert profile_response.status_code == 200

    preference_payload = {
        "signals": [
            {
                "signal_type": "meal",
                "name": "Chicken Shawarma",
                "score": 5,
                "weight": 4,
                "rationale": "Reliable family favorite.",
            },
            {
                "signal_type": "ingredient",
                "name": "Eggplant",
                "score": -5,
                "weight": 5,
                "rationale": "Avoid entirely.",
            },
            {
                "signal_type": "brand",
                "name": "Nature's Own",
                "score": 4,
                "weight": 3,
                "rationale": "Preferred bread brand.",
            },
        ]
    }
    preference_response = client.post("/api/preferences", json=preference_payload)
    assert preference_response.status_code == 200
    preference_context = preference_response.json()
    assert "Chicken Shawarma" in preference_context["summary"]["strong_likes"]
    assert "Eggplant" in preference_context["summary"]["hard_avoids"]
    assert any("Portable lunches preferred" in rule for rule in preference_context["summary"]["rules"])

    score_response = client.post(
        "/api/preferences/score-meal",
        json={
            "recipe_name": "Chicken Shawarma Bowls",
            "cuisine": "Middle Eastern",
            "ingredient_names": ["Chicken thighs", "Eggplant", "Rice"],
            "tags": ["nature's own wraps"],
        },
    )
    assert score_response.status_code == 200
    score_payload = score_response.json()
    assert score_payload["blocked"] is True
    assert any("Avoid ingredient: Eggplant" == blocker for blocker in score_payload["blockers"])
    assert any(match["name"] == "Chicken Shawarma" for match in score_payload["matches"])


def test_recipe_lifecycle_and_library_edits_do_not_change_planned_meals(client) -> None:
    metadata_response = client.get("/api/recipes/metadata")
    assert metadata_response.status_code == 200
    assert any(item["kind"] == "cuisine" for item in metadata_response.json()["cuisines"])
    assert metadata_response.json()["default_template_id"] == "recipe-template-standard"
    assert any(template["slug"] == "standard" for template in metadata_response.json()["templates"])

    new_tag_response = client.post("/api/recipes/metadata/tag", json={"name": "Low carb"})
    assert new_tag_response.status_code == 200
    assert new_tag_response.json()["name"] == "Low carb"

    create_recipe_response = client.post(
        "/api/recipes",
        json={
            "name": "Simple Pasta",
            "meal_type": "dinner",
            "cuisine": "Italian",
            "recipe_template_id": "recipe-template-weeknight",
            "servings": 4,
            "favorite": True,
            "notes": "Weeknight fallback",
            "tags": ["Quick", "Weeknight"],
            "ingredients": [],
            "steps": [
                {
                    "instruction": "Boil the pasta.",
                    "substeps": [{"instruction": "Salt the water."}],
                }
            ],
        },
    )
    assert create_recipe_response.status_code == 200
    recipe = create_recipe_response.json()
    assert recipe["name"] == "Simple Pasta"
    assert recipe["favorite"] is True
    assert recipe["archived"] is False
    assert recipe["updated_at"] is not None
    assert recipe["recipe_template_id"] == "recipe-template-weeknight"
    assert recipe["tags"] == ["Quick", "Weeknight"]
    assert recipe["steps"][0]["substeps"][0]["instruction"] == "Salt the water."

    list_response = client.get("/api/recipes?cuisine=Italian&tag=Quick")
    assert list_response.status_code == 200
    assert any(item["recipe_id"] == recipe["recipe_id"] for item in list_response.json())

    archive_response = client.post(f"/api/recipes/{recipe['recipe_id']}/archive")
    assert archive_response.status_code == 200
    archived_recipe = archive_response.json()
    assert archived_recipe["archived"] is True
    assert archived_recipe["archived_at"] is not None

    hidden_list_response = client.get("/api/recipes")
    assert hidden_list_response.status_code == 200
    assert all(item["recipe_id"] != recipe["recipe_id"] for item in hidden_list_response.json())

    archived_list_response = client.get("/api/recipes?include_archived=true")
    assert archived_list_response.status_code == 200
    assert any(item["recipe_id"] == recipe["recipe_id"] for item in archived_list_response.json())

    restore_response = client.post(f"/api/recipes/{recipe['recipe_id']}/restore")
    assert restore_response.status_code == 200
    restored_recipe = restore_response.json()
    assert restored_recipe["archived"] is False
    assert restored_recipe["archived_at"] is None

    create_week_response = client.post("/api/weeks", json={"week_start": "2026-03-30", "notes": "Recipe reuse"})
    assert create_week_response.status_code == 200
    week_id = create_week_response.json()["week_id"]

    save_meals_response = client.put(
        f"/api/weeks/{week_id}/meals",
        json=[
            {
                "day_name": "Monday",
                "meal_date": "2026-03-30",
                "slot": "dinner",
                "recipe_id": recipe["recipe_id"],
                "recipe_name": "Simple Pasta",
                "servings": 4,
                "scale_multiplier": 2,
                "notes": "",
                "approved": False,
            }
        ],
    )
    assert save_meals_response.status_code == 200

    edit_recipe_response = client.post(
        "/api/recipes",
        json={
            "recipe_id": recipe["recipe_id"],
            "name": "Simple Pasta Deluxe",
            "meal_type": "dinner",
            "servings": 6,
            "favorite": False,
            "notes": "Updated in library",
            "ingredients": [{"ingredient_name": "Pasta", "quantity": 1, "unit": "lb", "category": "Pantry"}],
        },
    )
    assert edit_recipe_response.status_code == 200
    edited_recipe = edit_recipe_response.json()
    assert edited_recipe["name"] == "Simple Pasta Deluxe"
    assert edited_recipe["favorite"] is False

    current_week_response = client.get("/api/weeks/current")
    assert current_week_response.status_code == 200
    current_week = current_week_response.json()
    assert current_week["updated_at"] is not None
    assert current_week["meals"][0]["updated_at"] is not None
    assert current_week["meals"][0]["recipe_id"] == recipe["recipe_id"]
    assert current_week["meals"][0]["recipe_name"] == "Simple Pasta"
    assert current_week["meals"][0]["scale_multiplier"] == 2

    delete_response = client.delete(f"/api/recipes/{recipe['recipe_id']}")
    assert delete_response.status_code == 204

    deleted_list_response = client.get("/api/recipes?include_archived=true")
    assert deleted_list_response.status_code == 200
    assert all(item["recipe_id"] != recipe["recipe_id"] for item in deleted_list_response.json())


def test_recipe_import_from_url_returns_clean_recipe_draft_and_preserves_source_metadata(client, monkeypatch) -> None:
    html = """
    <html>
      <head>
        <title>Best Lemon Pasta</title>
        <script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "Recipe",
            "name": "Lemon Pasta",
            "recipeCuisine": "Italian",
            "recipeYield": "4 servings",
            "prepTime": "PT15M",
            "cookTime": "PT20M",
            "keywords": "quick, weeknight, pasta",
            "recipeIngredient": [
              "1 lb spaghetti",
              "2 lemons",
              "Ingredients"
            ],
            "recipeInstructions": [
              {
                "@type": "HowToSection",
                "name": "Cook the pasta",
                "itemListElement": [
                  {"@type": "HowToStep", "text": "Boil the pasta."},
                  {"@type": "HowToStep", "text": "Reserve the pasta water."}
                ]
              },
              {"@type": "HowToStep", "text": "Toss with lemon juice and butter."}
            ],
            "publisher": {"@type": "Organization", "name": "Serious Eats"}
          }
        </script>
      </head>
      <body><article>Ignore the blog chrome.</article></body>
    </html>
    """.strip()

    class FakeResponse:
        def __init__(self, body: str) -> None:
            self._body = body.encode("utf-8")
            self.headers = {"Content-Type": "text/html; charset=utf-8"}

        def read(self) -> bytes:
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

    monkeypatch.setattr(recipe_import.urllib_request, "urlopen", lambda request, timeout=20.0: FakeResponse(html))

    import_response = client.post(
        "/api/recipes/import-from-url",
        json={"url": "https://www.seriouseats.com/lemon-pasta"},
    )
    assert import_response.status_code == 200
    imported = import_response.json()
    assert imported["name"] == "Lemon Pasta"
    assert imported["cuisine"] == "Italian"
    assert imported["servings"] == 4
    assert imported["prep_minutes"] == 15
    assert imported["cook_minutes"] == 20
    assert imported["source"] == "url_import"
    assert imported["source_label"] == "Serious Eats"
    assert imported["source_url"] == "https://www.seriouseats.com/lemon-pasta"
    assert [ingredient["ingredient_name"] for ingredient in imported["ingredients"]] == ["spaghetti", "lemons"]
    assert imported["ingredients"][0]["quantity"] == 1
    assert imported["ingredients"][0]["unit"] == "lb"
    assert imported["ingredients"][0]["normalized_name"] == "spaghetti"
    assert imported["ingredients"][1]["quantity"] == 2
    assert imported["ingredients"][1]["unit"] == ""
    assert imported["ingredients"][1]["normalized_name"] == "lemons"
    assert "Boil the pasta." in imported["instructions_summary"]
    assert "Ignore the blog chrome" not in imported["instructions_summary"]
    assert imported["steps"][0]["instruction"] == "Cook the pasta"
    assert imported["steps"][0]["substeps"][0]["instruction"] == "Boil the pasta."

    save_response = client.post("/api/recipes", json=imported)
    assert save_response.status_code == 200
    saved = save_response.json()
    assert saved["source"] == "url_import"
    assert saved["source_label"] == "Serious Eats"
    assert saved["source_url"] == "https://www.seriouseats.com/lemon-pasta"


def test_recipe_import_falls_back_to_html_instruction_lists_when_jsonld_steps_are_empty(client, monkeypatch) -> None:
    html = """
    <html>
      <head>
        <script type="application/ld+json">
          {
            "@context": "https://schema.org",
            "@type": "Recipe",
            "name": "Fallback Stir Fry",
            "recipeIngredient": ["1 bag slaw mix"],
            "recipeInstructions": [],
            "publisher": {"@type": "Organization", "name": "Example Site"}
          }
        </script>
      </head>
      <body>
        <article>
          <h2>Instructions</h2>
          <ol>
            <li>Heat the skillet.</li>
            <li>Toss in the vegetables.</li>
          </ol>
        </article>
      </body>
    </html>
    """.strip()

    class FakeResponse:
        def __init__(self, body: str) -> None:
            self._body = body.encode("utf-8")
            self.headers = {"Content-Type": "text/html; charset=utf-8"}

        def read(self) -> bytes:
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb) -> None:
            return None

    monkeypatch.setattr(recipe_import.urllib_request, "urlopen", lambda request, timeout=20.0: FakeResponse(html))

    import_response = client.post(
        "/api/recipes/import-from-url",
        json={"url": "https://example.com/fallback-stir-fry"},
    )
    assert import_response.status_code == 200
    imported = import_response.json()
    assert [step["instruction"] for step in imported["steps"]] == ["Heat the skillet.", "Toss in the vegetables."]


def test_recipe_import_from_text_returns_editable_draft(client) -> None:
    import_response = client.post(
        "/api/recipes/import-from-text",
        json={
            "title": "Whole Wheat Waffles",
            "source": "scan_import",
            "source_label": "Family recipe card",
            "text": """
Whole Wheat Waffles
Servings: 4
Prep Time: 10 minutes
Cook Time: 12 minutes
Tags: breakfast, freezer-friendly

Ingredients
- 2 cups whole wheat flour
- 2 eggs
- 1 3/4 cups milk
- 4 tbsp melted butter

Instructions
1. Whisk the dry ingredients together.
2. Add the wet ingredients and stir until combined.
3. Cook in a waffle iron until crisp.

Notes
Do not overmix the batter.
            """.strip(),
        },
    )

    assert import_response.status_code == 200
    imported = import_response.json()
    assert imported["name"] == "Whole Wheat Waffles"
    assert imported["source"] == "scan_import"
    assert imported["source_label"] == "Family recipe card"
    assert imported["servings"] == 4
    assert imported["prep_minutes"] == 10
    assert imported["cook_minutes"] == 12
    assert imported["tags"] == ["breakfast", "freezer-friendly"]
    assert [ingredient["ingredient_name"] for ingredient in imported["ingredients"]] == [
        "whole wheat flour",
        "eggs",
        "milk",
        "butter",
    ]
    assert imported["ingredients"][0]["quantity"] == 2
    assert imported["ingredients"][0]["unit"] == "cup"
    assert imported["ingredients"][1]["quantity"] == 2
    assert imported["ingredients"][1]["unit"] == ""
    assert imported["ingredients"][2]["quantity"] == 1.75
    assert imported["ingredients"][2]["unit"] == "cup"
    assert imported["ingredients"][3]["quantity"] == 4
    assert imported["ingredients"][3]["unit"] == "tbsp"
    assert imported["ingredients"][3]["prep"] == "melted"
    assert [step["instruction"] for step in imported["steps"]] == [
        "Whisk the dry ingredients together.",
        "Add the wet ingredients and stir until combined.",
        "Cook in a waffle iron until crisp.",
    ]
    assert imported["notes"] == "Do not overmix the batter."


def test_recipe_import_from_text_infers_scan_sections_without_headings(client) -> None:
    import_response = client.post(
        "/api/recipes/import-from-text",
        json={
            "source": "scan_import",
            "source_label": "Cookbook photo",
            "text": """
Whole Wheat Waffles
Page 1 of 2
Servings: 4
2 cups whole wheat flour
2 eggs
1 3/4 cups milk
4 tbsp melted butter
1. Whisk the dry ingredients together.
2. Add the wet ingredients and stir until combined.
3. Cook in a waffle iron until crisp.
            """.strip(),
        },
    )

    assert import_response.status_code == 200
    imported = import_response.json()
    assert imported["name"] == "Whole Wheat Waffles"
    assert [ingredient["ingredient_name"] for ingredient in imported["ingredients"]] == [
        "whole wheat flour",
        "eggs",
        "milk",
        "butter",
    ]
    assert [step["instruction"] for step in imported["steps"]] == [
        "Whisk the dry ingredients together.",
        "Add the wet ingredients and stir until combined.",
        "Cook in a waffle iron until crisp.",
    ]


def test_recipe_variation_draft_route_returns_draft_only_transform(client) -> None:
    create_recipe_response = client.post(
        "/api/recipes",
        json={
            "name": "Pad Thai",
            "meal_type": "dinner",
            "cuisine": "Thai",
            "servings": 4,
            "source": "manual",
            "ingredients": [
                {"ingredient_name": "8 oz rice noodles"},
                {"ingredient_name": "1 lb chicken thighs"},
                {"ingredient_name": "2 tbsp fish sauce"},
            ],
            "steps": [
                {"instruction": "Cook the rice noodles until tender."},
                {"instruction": "Stir-fry the chicken and toss with the noodles."},
            ],
        },
    )
    assert create_recipe_response.status_code == 200
    recipe = create_recipe_response.json()

    variation_response = client.post(
        f"/api/recipes/{recipe['recipe_id']}/ai/variation-draft",
        json={"goal": "Low-Carb"},
    )
    assert variation_response.status_code == 200
    payload = variation_response.json()
    assert payload["goal"] == "Low-Carb"
    assert payload["draft"]["recipe_id"] is None
    assert payload["draft"]["base_recipe_id"] == recipe["recipe_id"]
    assert payload["draft"]["name"] == "Low-Carb Pad Thai"
    assert payload["draft"]["source"] == "ai_variation"
    assert "low-carb" in payload["draft"]["tags"]
    assert any("zucchini noodles" in ingredient["ingredient_name"].lower() for ingredient in payload["draft"]["ingredients"])
    assert any("zucchini noodles" in step["instruction"].lower() for step in payload["draft"]["steps"])
    assert "Reduce starch-heavy ingredients" in payload["rationale"]

    list_response = client.get("/api/recipes?include_archived=true")
    assert list_response.status_code == 200
    assert len(list_response.json()) == 1


def test_recipe_suggestion_draft_route_returns_library_grounded_draft(client) -> None:
    create_recipe_response = client.post(
        "/api/recipes",
        json={
            "name": "Chicken Pasta Primavera",
            "meal_type": "dinner",
            "cuisine": "Italian",
            "favorite": True,
            "source": "url_import",
            "source_label": "Serious Eats",
            "ingredients": [
                {"ingredient_name": "1 lb pasta"},
                {"ingredient_name": "2 chicken breasts"},
                {"ingredient_name": "1 tbsp fresh basil"},
                {"ingredient_name": "2 cloves fresh garlic"},
            ],
            "steps": [
                {"instruction": "Cook the pasta."},
                {"instruction": "Saute the chicken with the vegetables."},
            ],
        },
    )
    assert create_recipe_response.status_code == 200
    recipe = create_recipe_response.json()

    suggestion_response = client.post(
        "/api/recipes/ai/suggestion-draft",
        json={"goal": "Pantry Reset"},
    )
    assert suggestion_response.status_code == 200
    payload = suggestion_response.json()
    assert payload["goal"] == "Pantry Reset"
    assert payload["draft"]["recipe_id"] is None
    assert payload["draft"]["base_recipe_id"] == recipe["recipe_id"]
    assert payload["draft"]["source"] == "ai_suggestion"
    assert payload["draft"]["meal_type"] == "dinner"
    assert "ai-suggested" in payload["draft"]["tags"]
    assert "pantry-friendly" in payload["draft"]["tags"]
    assert payload["draft"]["name"] == "Pantry-Friendly Chicken Pasta Primavera"
    assert "AI suggestion note:" in payload["draft"]["notes"]
    assert any("dried herbs" in ingredient["ingredient_name"].lower() for ingredient in payload["draft"]["ingredients"])
    assert "saved rotation" not in payload["rationale"].lower()
    assert "Started from Chicken Pasta Primavera" in payload["rationale"]

    list_response = client.get("/api/recipes?include_archived=true")
    assert list_response.status_code == 200
    assert len(list_response.json()) == 1


def test_recipe_companion_drafts_route_returns_three_draft_only_options(client) -> None:
    create_recipe_response = client.post(
        "/api/recipes",
        json={
            "name": "Smoked Beef Burnt Ends",
            "meal_type": "dinner",
            "cuisine": "American",
            "tags": ["barbecue"],
            "source": "url_import",
            "source_label": "Hey Grill Hey",
            "ingredients": [
                {"ingredient_name": "3 lb beef chuck roast", "quantity": 3, "unit": "lb", "category": "Meat"},
                {"ingredient_name": "2 tbsp yellow mustard", "quantity": 2, "unit": "tbsp", "category": "Condiments"},
            ],
            "steps": [
                {"instruction": "Smoke the beef until bark forms."},
                {"instruction": "Cube, sauce, and finish cooking until sticky."},
            ],
        },
    )
    assert create_recipe_response.status_code == 200
    recipe = create_recipe_response.json()

    companion_response = client.post(
        f"/api/recipes/{recipe['recipe_id']}/ai/companion-drafts",
        json={"focus": "sides_and_sauces"},
    )
    assert companion_response.status_code == 200
    payload = companion_response.json()
    assert payload["goal"] == "Sides and Sauces"
    assert len(payload["options"]) == 3
    assert [option["label"] for option in payload["options"]] == [
        "Vegetable Side",
        "Starch Side",
        "Sauce / Drizzle",
    ]
    assert len({option["option_id"] for option in payload["options"]}) == 3
    assert all(option["draft"]["recipe_id"] is None for option in payload["options"])
    assert all(option["draft"]["base_recipe_id"] is None for option in payload["options"])
    assert all(option["draft"]["source"] == "ai_companion" for option in payload["options"])
    assert all(option["draft"]["source_label"] == "Companion for Smoked Beef Burnt Ends" for option in payload["options"])
    assert all("companion" in option["draft"]["tags"] for option in payload["options"])
    assert any("companion-side" in option["draft"]["tags"] for option in payload["options"])
    assert any("companion-sauce" in option["draft"]["tags"] for option in payload["options"])
    assert all(option["draft"]["nutrition_summary"] is not None for option in payload["options"])

    list_response = client.get("/api/recipes?include_archived=true")
    assert list_response.status_code == 200
    assert len(list_response.json()) == 1


def test_recipe_companion_drafts_route_falls_back_when_cuisine_is_unknown(client) -> None:
    create_recipe_response = client.post(
        "/api/recipes",
        json={
            "name": "House Dinner",
            "meal_type": "dinner",
            "source": "manual",
            "ingredients": [{"ingredient_name": "2 chicken breasts"}],
            "steps": [{"instruction": "Cook the chicken."}],
        },
    )
    assert create_recipe_response.status_code == 200
    recipe = create_recipe_response.json()

    companion_response = client.post(
        f"/api/recipes/{recipe['recipe_id']}/ai/companion-drafts",
        json={"focus": "sides_and_sauces"},
    )
    assert companion_response.status_code == 200
    payload = companion_response.json()
    assert "neutral" in payload["rationale"].lower()
    assert payload["options"][0]["draft"]["name"] == "Roasted Lemon Green Beans"


def test_recipe_companion_drafts_route_returns_404_for_missing_recipe(client) -> None:
    companion_response = client.post(
        "/api/recipes/missing-recipe/ai/companion-drafts",
        json={"focus": "sides_and_sauces"},
    )
    assert companion_response.status_code == 404
    assert companion_response.json()["detail"] == "Recipe not found"


def test_week_flow_and_pricing_round_trip(client) -> None:
    create_response = client.post("/api/weeks", json={"week_start": "2026-03-16", "notes": "Family week"})
    assert create_response.status_code == 200
    week = create_response.json()
    week_id = week["week_id"]

    draft_payload = {
        "prompt": "Create a varied week draft.",
        "model": "test-model",
        "recipes": [
            {
                "recipe_id": "turkey-bowls",
                "name": "Turkey Bowls",
                "meal_type": "dinner",
                "servings": 4,
                "ingredients": [
                    {"ingredient_name": "Ground turkey", "quantity": 2, "unit": "lb", "category": "Meat"},
                    {"ingredient_name": "Rice", "quantity": 2, "unit": "cup", "category": "Pantry"},
                ],
            }
        ],
        "meal_plan": [
            {
                "day_name": "Monday",
                "meal_date": "2026-03-16",
                "slot": "dinner",
                "recipe_id": "turkey-bowls",
                "recipe_name": "Turkey Bowls",
                "servings": 4,
                "approved": False,
            },
            {
                "day_name": "Tuesday",
                "meal_date": "2026-03-17",
                "slot": "lunch",
                "recipe_name": "Yogurt Parfait",
                "servings": 2,
                "approved": False,
                "ingredients": [
                    {"ingredient_name": "Greek yogurt", "quantity": 32, "unit": "oz", "category": "Dairy"}
                ],
            },
            {
                "day_name": "Tuesday",
                "meal_date": "2026-03-17",
                "slot": "snack",
                "recipe_name": "Weekly snack restock",
                "servings": 1,
                "approved": False,
                "ingredients": [
                    {"ingredient_name": "Bananas", "quantity": 2, "unit": "bunch", "category": "Produce"}
                ],
            },
        ],
        "profile_updates": {"aldi_store_name": "Test Aldi", "walmart_store_name": "Test Walmart"},
    }
    draft_response = client.post(f"/api/weeks/{week_id}/draft-from-ai", json=draft_payload)
    assert draft_response.status_code == 200
    draft_week = draft_response.json()
    assert draft_week["status"] == "staging"
    assert draft_week["staged_change_count"] > 0
    assert len(draft_week["grocery_items"]) == 4
    snack_meal = next(meal for meal in draft_week["meals"] if meal["slot"] == "snack")
    assert snack_meal["approved"] is True

    changes_response = client.get(f"/api/weeks/{week_id}/changes")
    assert changes_response.status_code == 200
    change_batches = changes_response.json()
    assert len(change_batches) == 1
    assert change_batches[0]["actor_type"] == "agent_chat"

    ready_response = client.post(f"/api/weeks/{week_id}/ready-for-ai", json={})
    assert ready_response.status_code == 200
    ready_week = ready_response.json()
    assert ready_week["status"] == "ready_for_ai"
    assert ready_week["ready_for_ai_at"] is not None

    meal_updates = [
        {
            "meal_id": meal["meal_id"],
            "day_name": meal["day_name"],
            "meal_date": meal["meal_date"],
            "slot": meal["slot"],
            "recipe_id": meal["recipe_id"],
            "recipe_name": meal["recipe_name"],
            "servings": 6 if meal["slot"] == "dinner" else meal["servings"],
            "notes": "approved",
            "approved": True,
        }
        for meal in draft_week["meals"]
    ]
    update_response = client.put(f"/api/weeks/{week_id}/meals", json=meal_updates)
    assert update_response.status_code == 200
    updated_week = update_response.json()
    assert updated_week["status"] == "staging"
    assert all(meal["approved"] for meal in updated_week["meals"])

    dinner_meal = next(meal for meal in updated_week["meals"] if meal["slot"] == "dinner")
    feedback_response = client.post(
        f"/api/weeks/{week_id}/feedback",
        json=[
            {
                "meal_id": dinner_meal["meal_id"],
                "target_type": "meal",
                "target_name": dinner_meal["recipe_name"],
                "sentiment": 2,
                "reason_codes": ["family_hit"],
                "notes": "Worth repeating.",
            },
            {
                "target_type": "brand",
                "target_name": "Nature's Own",
                "sentiment": 1,
                "reason_codes": ["portable_lunch_win"],
                "notes": "Still the best sandwich bread.",
            },
        ],
    )
    assert feedback_response.status_code == 200
    feedback_payload = feedback_response.json()
    assert feedback_payload["summary"]["meal_entries"] == 1
    assert feedback_payload["summary"]["brand_entries"] == 1

    meal_export_response = client.post(
        f"/api/weeks/{week_id}/exports",
        json={"destination": "apple_reminders", "export_type": "meal_plan"},
    )
    assert meal_export_response.status_code == 200
    meal_export = meal_export_response.json()
    assert meal_export["status"] == "pending"
    assert meal_export["item_count"] == 2
    assert meal_export["updated_at"] is not None

    meal_export_payload_response = client.get(f"/api/exports/{meal_export['export_id']}/apple-reminders")
    assert meal_export_payload_response.status_code == 200
    meal_export_payload = meal_export_payload_response.json()
    assert [item["title"] for item in meal_export_payload["items"]] == [
        "Monday - Dinner: Turkey Bowls",
        "Tuesday - Lunch: Yogurt Parfait",
    ]

    complete_meal_export_response = client.post(
        f"/api/exports/{meal_export['export_id']}/complete",
        json={"status": "completed", "external_ref": "Meals"},
    )
    assert complete_meal_export_response.status_code == 200
    assert complete_meal_export_response.json()["status"] == "completed"

    approve_response = client.post(f"/api/weeks/{week_id}/approve", json={})
    assert approve_response.status_code == 200
    assert approve_response.json()["status"] == "approved"

    pricing_items = []
    for item in updated_week["grocery_items"]:
        is_turkey = "turkey" in item["ingredient_name"].lower()
        pricing_items.extend(
            [
                {
                    "grocery_item_id": item["grocery_item_id"],
                    "retailer": "aldi",
                    "status": "matched",
                    "store_name": "Test Aldi 60601",
                    "product_name": item["ingredient_name"],
                    "package_size": "1 lb" if is_turkey else "32 oz",
                    "unit_price": 4.0 if is_turkey else 5.5,
                    "line_price": 4.0 if is_turkey else 5.5,
                    "product_url": f"https://aldi.test/{item['grocery_item_id']}",
                    "availability": "In stock",
                    "candidate_score": 0.91,
                    "raw_query": item["ingredient_name"],
                },
                {
                    "grocery_item_id": item["grocery_item_id"],
                    "retailer": "walmart",
                    "status": "matched",
                    "store_name": "Test Walmart 60601",
                    "product_name": item["ingredient_name"],
                    "package_size": "1 lb" if is_turkey else "32 oz",
                    "unit_price": 4.5 if is_turkey else 6.0,
                    "line_price": 4.5 if is_turkey else 6.0,
                    "product_url": f"https://walmart.test/{item['grocery_item_id']}",
                    "availability": "In stock",
                    "candidate_score": 0.88,
                    "raw_query": item["ingredient_name"],
                },
            ]
        )
        if is_turkey:
            pricing_items.append(
                {
                    "grocery_item_id": item["grocery_item_id"],
                    "retailer": "sams_club",
                    "status": "matched",
                    "store_name": "Test Sam's Club 60601",
                    "product_name": f"{item['ingredient_name']} bulk pack",
                    "package_size": "3 lb",
                    "unit_price": 4.25,
                    "line_price": 8.5,
                    "product_url": f"https://sams.test/{item['grocery_item_id']}",
                    "availability": "In stock",
                    "candidate_score": 0.86,
                    "raw_query": item["ingredient_name"],
                }
            )

    pricing_response = client.post(
        f"/api/weeks/{week_id}/pricing/import",
        json={"items": pricing_items, "replace_existing": True},
    )
    assert pricing_response.status_code == 200
    pricing = pricing_response.json()
    assert pricing["totals"]["aldi"] > 0
    assert pricing["totals"]["walmart"] > pricing["totals"]["aldi"]
    assert pricing["totals"]["sams_club"] > 0

    shopping_export_response = client.post(
        f"/api/weeks/{week_id}/exports",
        json={"destination": "apple_reminders", "export_type": "shopping_split"},
    )
    assert shopping_export_response.status_code == 200
    shopping_export = shopping_export_response.json()
    assert shopping_export["status"] == "pending"
    assert shopping_export["item_count"] == len(updated_week["grocery_items"])

    current_week_response = client.get("/api/weeks/current")
    assert current_week_response.status_code == 200
    current_week = current_week_response.json()
    assert current_week["status"] == "priced"
    assert current_week["updated_at"] is not None
    assert any(item["retailer_prices"] for item in current_week["grocery_items"])
    assert all(item["updated_at"] is not None for item in current_week["grocery_items"])
    assert current_week["feedback_count"] == 2
    assert current_week["export_count"] == 2

    weeks_response = client.get("/api/weeks?limit=6")
    assert weeks_response.status_code == 200
    weeks = weeks_response.json()
    assert weeks[0]["week_start"] == "2026-03-16"
    assert weeks[0]["updated_at"] is not None
    assert weeks[0]["meal_count"] == 3


def test_api_token_auth_protects_routes_when_configured(client, monkeypatch) -> None:
    from app.config import get_settings

    monkeypatch.setenv("SIMMERSMITH_API_TOKEN", "ios-secret")
    get_settings.cache_clear()

    unauthorized = client.get("/api/profile")
    assert unauthorized.status_code == 401

    wrong_token = client.get("/api/profile", headers={"Authorization": "Bearer nope"})
    assert wrong_token.status_code == 401

    authorized = client.get("/api/profile", headers={"Authorization": "Bearer ios-secret"})
    assert authorized.status_code == 200

    health = client.get("/api/health")
    assert health.status_code == 200


def test_manual_week_authoring_supports_partial_plan_and_slot_removal(client) -> None:
    create_response = client.post("/api/weeks", json={"week_start": "2026-03-23", "notes": "Manual planning"})
    assert create_response.status_code == 200
    week = create_response.json()
    week_id = week["week_id"]

    manual_plan = [
        {
            "day_name": "Monday",
            "meal_date": "2026-03-23",
            "slot": "dinner",
            "recipe_name": "Sheet Pan Sausage",
            "recipe_id": None,
            "servings": 4,
            "notes": "Use broccoli on hand",
            "approved": False,
        },
        {
            "day_name": "Wednesday",
            "meal_date": "2026-03-25",
            "slot": "lunch",
            "recipe_name": "Turkey sandwiches",
            "recipe_id": None,
            "servings": 2,
            "notes": "",
            "approved": True,
        },
    ]
    first_save = client.put(f"/api/weeks/{week_id}/meals", json=manual_plan)
    assert first_save.status_code == 200
    saved_week = first_save.json()
    assert saved_week["status"] == "staging"
    assert len(saved_week["meals"]) == 2
    assert {meal["slot"] for meal in saved_week["meals"]} == {"dinner", "lunch"}
    assert len(saved_week["grocery_items"]) == 0

    changes_response = client.get(f"/api/weeks/{week_id}/changes")
    assert changes_response.status_code == 200
    change_batches = changes_response.json()
    assert change_batches[0]["actor_type"] == "user_ui"
    assert "Planned" in change_batches[0]["summary"]

    monday_dinner = next(meal for meal in saved_week["meals"] if meal["day_name"] == "Monday")
    revised_plan = [
        {
            "meal_id": monday_dinner["meal_id"],
            "day_name": monday_dinner["day_name"],
            "meal_date": monday_dinner["meal_date"],
            "slot": monday_dinner["slot"],
            "recipe_name": "Sheet Pan Sausage and Peppers",
            "recipe_id": monday_dinner["recipe_id"],
            "servings": 5,
            "notes": "Add extra peppers",
            "approved": True,
        }
    ]
    second_save = client.put(f"/api/weeks/{week_id}/meals", json=revised_plan)
    assert second_save.status_code == 200
    revised_week = second_save.json()
    assert len(revised_week["meals"]) == 1
    assert revised_week["meals"][0]["recipe_name"] == "Sheet Pan Sausage and Peppers"
    assert revised_week["meals"][0]["approved"] is True


def test_recipe_nutrition_summary_and_variation_recalculation(client) -> None:
    base_response = client.post(
        "/api/recipes",
        json={
            "name": "Pad Thai Base",
            "meal_type": "dinner",
            "servings": 4,
            "ingredients": [
                {"ingredient_name": "Spaghetti", "quantity": 8, "unit": "oz"},
                {"ingredient_name": "Butter", "quantity": 2, "unit": "tbsp"},
            ],
            "steps": [{"instruction": "Cook and toss."}],
        },
    )
    assert base_response.status_code == 200
    base_recipe = base_response.json()
    assert base_recipe["nutrition_summary"]["coverage_status"] == "complete"
    assert base_recipe["nutrition_summary"]["calories_per_serving"] == 251.0

    variation_response = client.post(
        "/api/recipes",
        json={
            "base_recipe_id": base_recipe["recipe_id"],
            "name": "Pad Thai Carrot Variation",
            "meal_type": "dinner",
            "servings": 4,
            "ingredients": [
                {"ingredient_name": "Carrots", "quantity": 4, "unit": "cup"},
                {"ingredient_name": "Butter", "quantity": 2, "unit": "tbsp"},
            ],
            "steps": [{"instruction": "Cook and toss."}],
        },
    )
    assert variation_response.status_code == 200
    variation_recipe = variation_response.json()
    assert variation_recipe["nutrition_summary"]["coverage_status"] == "complete"
    assert variation_recipe["nutrition_summary"]["calories_per_serving"] == 103.0
    assert variation_recipe["nutrition_summary"]["calories_per_serving"] < base_recipe["nutrition_summary"]["calories_per_serving"]

    detail_response = client.get(f"/api/recipes/{variation_recipe['recipe_id']}")
    assert detail_response.status_code == 200
    assert detail_response.json()["nutrition_summary"]["calories_per_serving"] == 103.0


def test_recipe_nutrition_estimate_search_and_matching(client) -> None:
    payload = {
        "name": "Draft Estimate",
        "meal_type": "dinner",
        "servings": 2,
        "ingredients": [
            {"ingredient_name": "Carrots", "quantity": 2, "unit": "cup"},
            {"ingredient_name": "Mystery Sauce", "quantity": 1, "unit": "cup"},
        ],
    }

    estimate_response = client.post("/api/recipes/nutrition/estimate", json=payload)
    assert estimate_response.status_code == 200
    estimate = estimate_response.json()
    assert estimate["coverage_status"] == "partial"
    assert estimate["matched_ingredient_count"] == 1
    assert estimate["unmatched_ingredients"] == ["Mystery Sauce"]
    assert estimate["calories_per_serving"] == 52.0

    search_response = client.get("/api/recipes/nutrition/search?q=butter")
    assert search_response.status_code == 200
    butter = next(item for item in search_response.json() if item["normalized_name"] == "butter")

    match_response = client.post(
        "/api/recipes/nutrition/matches",
        json={
            "ingredient_name": "Mystery Sauce",
            "normalized_name": "mystery sauce",
            "nutrition_item_id": butter["item_id"],
        },
    )
    assert match_response.status_code == 200
    assert match_response.json()["nutrition_item"]["normalized_name"] == "butter"

    matched_estimate_response = client.post("/api/recipes/nutrition/estimate", json=payload)
    assert matched_estimate_response.status_code == 200
    matched_estimate = matched_estimate_response.json()
    assert matched_estimate["coverage_status"] == "complete"
    assert matched_estimate["unmatched_ingredients"] == []
    assert matched_estimate["calories_per_serving"] == 868.0


def test_assistant_thread_lifecycle(client) -> None:
    create_response = client.post("/api/assistant/threads", json={"title": "Recipe Coach"})
    assert create_response.status_code == 200
    thread = create_response.json()
    assert thread["title"] == "Recipe Coach"

    list_response = client.get("/api/assistant/threads")
    assert list_response.status_code == 200
    assert any(item["thread_id"] == thread["thread_id"] for item in list_response.json())

    detail_response = client.get(f"/api/assistant/threads/{thread['thread_id']}")
    assert detail_response.status_code == 200
    assert detail_response.json()["messages"] == []

    delete_response = client.delete(f"/api/assistant/threads/{thread['thread_id']}")
    assert delete_response.status_code == 204

    archived_list_response = client.get("/api/assistant/threads")
    assert archived_list_response.status_code == 200
    assert all(item["thread_id"] != thread["thread_id"] for item in archived_list_response.json())


def test_assistant_respond_stream_persists_messages_and_recipe_draft(client, monkeypatch) -> None:
    def fake_run_assistant_turn(**_: object) -> AssistantTurnResult:
        return AssistantTurnResult(
            target=AssistantExecutionTarget(
                provider_kind="mcp",
                source="server",
                model="codex",
                provider_name="codex",
                mcp_server_name="codex",
            ),
            prompt="Create a whole wheat waffle recipe",
            raw_output='{"assistant_markdown":"Here is a starter waffle recipe.","recipe_draft":{"name":"Whole Wheat Waffles","meal_type":"breakfast","cuisine":"American","servings":4,"ingredients":[{"ingredient_name":"whole wheat flour","quantity":2,"unit":"cup","category":"Pantry"}],"steps":[{"instruction":"Whisk the batter."}]}}',
            envelope=AssistantProviderEnvelope.model_validate(
                {
                    "assistant_markdown": "Here is a starter waffle recipe.",
                    "recipe_draft": {
                        "name": "Whole Wheat Waffles",
                        "meal_type": "breakfast",
                        "cuisine": "American",
                        "servings": 4,
                        "ingredients": [
                            {
                                "ingredient_name": "whole wheat flour",
                                "quantity": 2,
                                "unit": "cup",
                                "category": "Pantry",
                            }
                        ],
                        "steps": [{"instruction": "Whisk the batter."}],
                    },
                }
            ),
            provider_thread_id="mcp-thread-1",
        )

    monkeypatch.setattr("app.api.assistant.run_assistant_turn", fake_run_assistant_turn)

    thread_response = client.post("/api/assistant/threads", json={"title": "Breakfast ideas"})
    assert thread_response.status_code == 200
    thread_id = thread_response.json()["thread_id"]

    with client.stream(
        "POST",
        f"/api/assistant/threads/{thread_id}/respond",
        json={"text": "Create a whole wheat waffle recipe", "intent": "recipe_creation"},
    ) as response:
        assert response.status_code == 200
        body = "".join(response.iter_text())

    assert "event: user_message.created" in body
    assert "event: assistant.recipe_draft" in body
    assert "event: assistant.completed" in body

    detail_response = client.get(f"/api/assistant/threads/{thread_id}")
    assert detail_response.status_code == 200
    payload = detail_response.json()
    assert len(payload["messages"]) == 2
    assert payload["messages"][1]["content_markdown"] == "Here is a starter waffle recipe."
    assert payload["messages"][1]["recipe_draft"]["name"] == "Whole Wheat Waffles"


def test_assistant_sse_encoding_uses_jsonable_dates() -> None:
    payload = {
        "thread_id": "thread-1",
        "created_at": datetime(2026, 3, 29, 1, 30, 0, tzinfo=UTC),
    }
    encoded = encode_sse("thread.updated", payload)
    assert "event: thread.updated" in encoded
    assert '"created_at": "2026-03-29T01:30:00+00:00"' in encoded


def test_assistant_strict_schema_marks_all_object_properties_required() -> None:
    schema = strict_json_schema(AssistantProviderEnvelope)
    assert schema["additionalProperties"] is False
    assert sorted(schema["required"]) == ["assistant_markdown", "recipe_draft"]

    recipe_payload_schema = schema["$defs"]["RecipePayload"]
    assert recipe_payload_schema["additionalProperties"] is False
    assert "name" in recipe_payload_schema["required"]
    assert "recipe_id" in recipe_payload_schema["required"]

    serialized = json.dumps(schema)
    assert '"additionalProperties": false' in serialized
