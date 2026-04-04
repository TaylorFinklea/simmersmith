import Foundation
import Testing
@testable import SimmerSmithKit

@Test
func normalizeServerURLAddsSchemeAndTrimsTrailingSlash() {
    #expect(ConnectionSettingsStore.normalizeServerURL("localhost:8080/") == "http://localhost:8080")
    #expect(ConnectionSettingsStore.normalizeServerURL("https://example.com///") == "https://example.com")
    #expect(ConnectionSettingsStore.normalizeServerURL("127.0.0.1:8080/api") == "http://127.0.0.1:8080")
    #expect(ConnectionSettingsStore.normalizeServerURL("http://10.15.109.184:8080/api/health") == "http://10.15.109.184:8080")
}

@Test
func connectionSettingsStoreLoadsTokenFromFallbackDefaults() {
    let suiteName = "SimmerSmithKitTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("http://127.0.0.1:8080", forKey: ConnectionSettingsStore.Keys.serverURL)
    defaults.set("fallback-token", forKey: ConnectionSettingsStore.Keys.authTokenFallback)

    let keychain = KeychainStore(service: "SimmerSmithKitTests-\(UUID().uuidString)")
    let store = ConnectionSettingsStore(defaults: defaults, keychain: keychain)
    let connection = store.load()

    #expect(connection.serverURLString == "http://127.0.0.1:8080")
    #expect(connection.authToken == "fallback-token")
}

@Test
func decoderHandlesProductLikeBaseIngredientPayload() throws {
    let json = """
    {
      "base_ingredient_id": "ingredient-1",
      "name": "Classic Yellow Mustard",
      "normalized_name": "classic yellow mustard",
      "category": "Condiments",
      "default_unit": "jar",
      "notes": "Package-form product",
      "source_name": "Open Food Facts",
      "source_record_id": "0123456789",
      "source_u_r_l": "https://example.com/mustard",
      "provisional": false,
      "active": true,
      "nutrition_reference_amount": 15,
      "nutrition_reference_unit": "g",
      "calories": 20,
      "archived_at": null,
      "merged_into_id": null,
      "variation_count": 2,
      "preference_count": 1,
      "recipe_usage_count": 4,
      "grocery_usage_count": 3,
      "product_like": true,
      "updated_at": "2026-03-23T19:30:00Z"
    }
    """.data(using: .utf8)!

    let ingredient = try SimmerSmithJSONCoding.makeDecoder().decode(BaseIngredient.self, from: json)

    #expect(ingredient.id == "ingredient-1")
    #expect(ingredient.productLike)
    #expect(ingredient.sourceName == "Open Food Facts")
    #expect(ingredient.variationCount == 2)
    #expect(ingredient.nutritionReferenceUnit == "g")
}

@Test
func decoderHandlesAssistantThreadPayloadWithNestedRecipeDraft() throws {
    let json = """
    {
      "thread_id": "thread-1",
      "title": "Dinner ideas",
      "preview": "Try a lighter weeknight bowl.",
      "created_at": "2026-03-23T19:30:00Z",
      "updated_at": "2026-03-23T19:45:00Z",
      "messages": [
        {
          "message_id": "message-1",
          "thread_id": "thread-1",
          "role": "assistant",
          "status": "completed",
          "content_markdown": "Here is a draft.",
          "recipe_draft": {
            "name": "Weeknight Bowl",
            "meal_type": "dinner",
            "cuisine": "fusion",
            "servings": 4,
            "tags": ["quick", "balanced"],
            "favorite": false,
            "source": "assistant",
            "source_label": "codex",
            "source_url": "",
            "notes": "Keep the sauce light.",
            "memories": "",
            "ingredients": [
              {
                "ingredient_name": "Chicken",
                "normalized_name": "chicken",
                "resolution_status": "resolved",
                "quantity": 1,
                "unit": "lb",
                "prep": "cubed",
                "category": "Protein",
                "notes": ""
              }
            ],
            "steps": [
              {
                "sort_order": 1,
                "instruction": "Sear the chicken."
              }
            ]
          },
          "attached_recipe_id": "recipe-1",
          "created_at": "2026-03-23T19:30:00Z",
          "completed_at": "2026-03-23T19:31:00Z",
          "error": ""
        },
        {
          "message_id": "message-2",
          "thread_id": "thread-1",
          "role": "assistant",
          "status": "failed",
          "content_markdown": "",
          "recipe_draft": null,
          "attached_recipe_id": null,
          "created_at": "2026-03-23T19:32:00Z",
          "completed_at": null,
          "error": "Provider timeout"
        }
      ]
    }
    """.data(using: .utf8)!

    let thread = try SimmerSmithJSONCoding.makeDecoder().decode(AssistantThread.self, from: json)

    #expect(thread.id == "thread-1")
    #expect(thread.messages.count == 2)
    #expect(thread.messages.first?.recipeDraft?.ingredients.first?.resolutionStatus == "resolved")
    #expect(thread.messages.last?.error == "Provider timeout")
}

@Test
func decoderHandlesRecipeIngredientDefaultsAndIdentityFallback() throws {
    let json = """
    {
      "ingredient_name": "Bread",
      "quantity": 2,
      "unit": "slice",
      "prep": "toasted",
      "category": "Bakery",
      "notes": "Use day-old bread."
    }
    """.data(using: .utf8)!

    let ingredient = try SimmerSmithJSONCoding.makeDecoder().decode(RecipeIngredient.self, from: json)

    #expect(ingredient.id == "Bread")
    #expect(ingredient.resolutionStatus == "unresolved")
    #expect(ingredient.quantity == 2)
    #expect(ingredient.unit == "slice")
}

@Test
func decoderHandlesExportRunPayloadWithItemsAndOptionalCompletionState() throws {
    let json = """
    {
      "export_id": "export-1",
      "destination": "apple_reminders",
      "export_type": "meal_plan",
      "status": "pending",
      "item_count": 2,
      "payload_json": "{\\"week_id\\":\\"week-1\\"}",
      "error": "",
      "external_ref": "",
      "created_at": "2026-03-23T19:30:00Z",
      "completed_at": null,
      "updated_at": "2026-03-23T19:31:00Z",
      "items": [
        {
          "export_item_id": "export-item-1",
          "sort_order": 1,
          "list_name": "meal_plan",
          "title": "Monday - Dinner: Turkey Bowls",
          "notes": "",
          "metadata_json": "{}",
          "status": "pending"
        },
        {
          "export_item_id": "export-item-2",
          "sort_order": 2,
          "list_name": "meal_plan",
          "title": "Tuesday - Lunch: Yogurt Parfait",
          "notes": "",
          "metadata_json": "{}",
          "status": "pending"
        }
      ]
    }
    """.data(using: .utf8)!

    let exportRun = try SimmerSmithJSONCoding.makeDecoder().decode(ExportRun.self, from: json)

    #expect(exportRun.id == "export-1")
    #expect(exportRun.itemCount == 2)
    #expect(exportRun.completedAt == nil)
    #expect(exportRun.items.map(\.title) == [
        "Monday - Dinner: Turkey Bowls",
        "Tuesday - Lunch: Yogurt Parfait"
    ])
}

@Test
func decoderHandlesDateOnlyAndDateTimePayloads() throws {
    let json = """
    {
      "week_id": "week-1",
      "week_start": "2026-03-23",
      "week_end": "2026-03-29",
      "status": "staging",
      "notes": "",
      "ready_for_ai_at": null,
      "approved_at": null,
      "priced_at": null,
      "updated_at": "2026-03-23T19:30:00Z",
      "staged_change_count": 0,
      "feedback_count": 0,
      "export_count": 0,
      "meals": [
        {
          "meal_id": "meal-1",
          "day_name": "Monday",
          "meal_date": "2026-03-23",
          "slot": "dinner",
          "recipe_id": "recipe-1",
          "recipe_name": "Pad Thai",
          "servings": 4,
          "scale_multiplier": 2,
          "source": "user",
          "approved": false,
          "notes": "",
          "ai_generated": false,
          "updated_at": "2026-03-23T19:30:00Z",
          "ingredients": []
        }
      ],
      "grocery_items": []
    }
    """.data(using: .utf8)!

    let week = try SimmerSmithJSONCoding.makeDecoder().decode(WeekSnapshot.self, from: json)
    let calendar = Calendar(identifier: .iso8601)
    #expect(calendar.component(.year, from: week.weekStart) == 2026)
    #expect(week.status == "staging")
    #expect(week.meals.first?.scaleMultiplier == 2)
}

@Test
func decoderHandlesServerDatetimeWithoutTimezone() throws {
    let json = """
    {
      "updated_at": "2026-03-15T00:36:12.892523",
      "settings": {
        "week_start_day": "Monday"
      },
      "staples": []
    }
    """.data(using: .utf8)!

    let profile = try SimmerSmithJSONCoding.makeDecoder().decode(ProfileSnapshot.self, from: json)
    #expect(profile.updatedAt != nil)
    #expect(profile.settings["week_start_day"] == "Monday")
    #expect(profile.secretFlags.isEmpty)
}

@Test
func decoderHandlesSnakeCaseAcronymFieldsInRecipeAndWeekPayloads() throws {
    let recipeJSON = """
    {
      "recipe_id": "recipe-1",
      "name": "Imported Recipe",
      "meal_type": "dinner",
      "cuisine": "",
      "servings": 4,
      "prep_minutes": 10,
      "cook_minutes": 20,
      "tags": ["quick", "weeknight"],
      "instructions_summary": "",
      "favorite": false,
      "archived": false,
      "source": "url",
      "source_label": "Example Site",
      "source_url": "https://example.com/recipe",
      "notes": "",
      "last_used": null,
      "archived_at": null,
      "updated_at": "2026-03-23T19:30:00.000000",
      "ingredients": []
    }
    """.data(using: .utf8)!

    let weekJSON = """
    {
      "week_id": "week-1",
      "week_start": "2026-03-23",
      "week_end": "2026-03-29",
      "status": "priced",
      "notes": "",
      "ready_for_ai_at": null,
      "approved_at": null,
      "priced_at": "2026-03-23T19:30:00.000000",
      "updated_at": "2026-03-23T19:30:00.000000",
      "staged_change_count": 0,
      "feedback_count": 0,
      "export_count": 0,
      "meals": [],
      "grocery_items": [
        {
          "grocery_item_id": "grocery-1",
          "ingredient_name": "Bread",
          "normalized_name": "bread",
          "total_quantity": 1,
          "unit": "loaf",
          "quantity_text": "",
          "category": "Bakery",
          "source_meals": "",
          "notes": "",
          "review_flag": "",
          "updated_at": "2026-03-23T19:30:00.000000",
          "retailer_prices": [
            {
              "retailer": "walmart",
              "status": "matched",
              "store_name": "Store",
              "product_name": "Bread",
              "package_size": "1 loaf",
              "unit_price": 3.5,
              "line_price": 3.5,
              "product_url": "https://example.com/product",
              "availability": "Pickup",
              "candidate_score": 0.95,
              "review_note": "",
              "raw_query": "bread",
              "scraped_at": "2026-03-23T19:30:00.000000"
            }
          ]
        }
      ]
    }
    """.data(using: .utf8)!

    let recipe = try SimmerSmithJSONCoding.makeDecoder().decode(RecipeSummary.self, from: recipeJSON)
    let week = try SimmerSmithJSONCoding.makeDecoder().decode(WeekSnapshot.self, from: weekJSON)

    #expect(recipe.sourceUrl == "https://example.com/recipe")
    #expect(recipe.tags == ["quick", "weeknight"])
    #expect(week.groceryItems.first?.retailerPrices.first?.productUrl == "https://example.com/product")
}

@Test
func decoderHandlesRecipeMetadataPayload() throws {
    let json = """
    {
      "updated_at": "2026-03-23T19:30:00.000000",
      "default_template_id": "recipe-template-standard",
      "cuisines": [
        {
          "item_id": "cuisine-1",
          "kind": "cuisine",
          "name": "Thai",
          "normalized_name": "thai",
          "updated_at": "2026-03-23T19:30:00.000000"
        }
      ],
      "tags": [
        {
          "item_id": "tag-1",
          "kind": "tag",
          "name": "Low carb",
          "normalized_name": "low carb",
          "updated_at": "2026-03-23T19:30:00.000000"
        }
      ],
      "units": [
        {
          "item_id": "unit-1",
          "kind": "unit",
          "name": "cup",
          "normalized_name": "cup",
          "updated_at": "2026-03-23T19:30:00.000000"
        }
      ],
      "templates": [
        {
          "template_id": "recipe-template-standard",
          "slug": "standard",
          "name": "Standard",
          "description": "Balanced",
          "section_order": ["title", "ingredients", "steps"],
          "share_source": true,
          "share_memories": true,
          "built_in": true,
          "updated_at": "2026-03-23T19:30:00.000000"
        }
      ]
    }
    """.data(using: .utf8)!

    let metadata = try SimmerSmithJSONCoding.makeDecoder().decode(RecipeMetadata.self, from: json)

    #expect(metadata.cuisines.first?.name == "Thai")
    #expect(metadata.tags.first?.normalizedName == "low carb")
    #expect(metadata.units.first?.name == "cup")
    #expect(metadata.defaultTemplateId == "recipe-template-standard")
    #expect(metadata.templates.first?.name == "Standard")
}

@Test
func decoderHandlesHealthCapabilitiesPayload() throws {
    let json = """
    {
      "status": "ok",
      "ai_capabilities": {
        "supports_user_override": true,
        "preferred_mode": "auto",
        "user_override_provider": "openai",
        "user_override_configured": true,
        "default_target": {
          "provider_kind": "mcp",
          "mode": "mcp",
          "source": "server",
          "mcp_server_name": "codex"
        },
        "available_providers": [
          {
            "provider_id": "mcp",
            "label": "codex",
            "provider_kind": "mcp",
            "available": true,
            "source": "server"
          }
        ]
      }
    }
    """.data(using: .utf8)!

    let health = try SimmerSmithJSONCoding.makeDecoder().decode(HealthResponse.self, from: json)

    #expect(health.status == "ok")
    #expect(health.aiCapabilities?.defaultTarget?.mcpServerName == "codex")
    #expect(health.aiCapabilities?.availableProviders.first?.providerId == "mcp")
}

@Test
func decoderHandlesProviderModelsPayload() throws {
    let json = """
    {
      "provider_id": "openai",
      "selected_model_id": "gpt-4.1-mini",
      "source": "user_override",
      "models": [
        {
          "provider_id": "openai",
          "model_id": "gpt-4.1-mini",
          "display_name": "gpt-4.1-mini"
        },
        {
          "provider_id": "openai",
          "model_id": "gpt-4.1",
          "display_name": "gpt-4.1"
        }
      ]
    }
    """.data(using: .utf8)!

    let payload = try SimmerSmithJSONCoding.makeDecoder().decode(AIProviderModels.self, from: json)

    #expect(payload.providerId == "openai")
    #expect(payload.selectedModelId == "gpt-4.1-mini")
    #expect(payload.models.count == 2)
    #expect(payload.models.first?.modelId == "gpt-4.1-mini")
}

@Test
func decoderHandlesIngredientPreferencePayload() throws {
    let json = """
    {
      "preference_id": "pref-1",
      "base_ingredient_id": "base-1",
      "base_ingredient_name": "Refrigerated biscuits",
      "preferred_variation_id": "var-1",
      "preferred_variation_name": "Pillsbury Grands! Biscuits",
      "preferred_brand": "Pillsbury",
      "choice_mode": "preferred",
      "active": true,
      "notes": "Use this unless a recipe locks another brand.",
      "updated_at": "2026-03-30T18:05:00.000000"
    }
    """.data(using: .utf8)!

    let payload = try SimmerSmithJSONCoding.makeDecoder().decode(IngredientPreference.self, from: json)

    #expect(payload.preferenceId == "pref-1")
    #expect(payload.baseIngredientName == "Refrigerated biscuits")
    #expect(payload.preferredVariationName == "Pillsbury Grands! Biscuits")
    #expect(payload.choiceMode == "preferred")
    #expect(payload.active)
}

@Test
func decoderHandlesSnakeCaseAcronymFieldsInExportPayloads() throws {
    let json = """
    {
      "export_id": "export-1",
      "destination": "reminders",
      "export_type": "shopping",
      "status": "queued",
      "item_count": 1,
      "payload_json": "{\\"list\\":\\"Shopping\\"}",
      "error": "",
      "external_ref": "",
      "created_at": "2026-03-23T19:30:00.000000",
      "completed_at": null,
      "updated_at": "2026-03-23T19:30:00.000000",
      "items": [
        {
          "export_item_id": "item-1",
          "sort_order": 0,
          "list_name": "Shopping",
          "title": "Bread",
          "notes": "",
          "metadata_json": "{\\"foo\\":\\"bar\\"}",
          "status": "queued"
        }
      ]
    }
    """.data(using: .utf8)!

    let export = try SimmerSmithJSONCoding.makeDecoder().decode(ExportRun.self, from: json)

    #expect(export.payloadJson == "{\"list\":\"Shopping\"}")
    #expect(export.items.first?.metadataJson == "{\"foo\":\"bar\"}")
}

@Test
func decoderHandlesNutritionSummaryAndNutritionCatalogPayloads() throws {
    let recipeJSON = """
    {
      "recipe_id": "recipe-1",
      "name": "Pad Thai",
      "meal_type": "dinner",
      "cuisine": "Thai",
      "servings": 4,
      "prep_minutes": 15,
      "cook_minutes": 20,
      "tags": ["weeknight"],
      "instructions_summary": "",
      "favorite": false,
      "archived": false,
      "source": "manual",
      "source_label": "",
      "source_url": "",
      "notes": "",
      "memories": "",
      "last_used": null,
      "family_last_used": null,
      "days_since_last_used": null,
      "family_days_since_last_used": null,
      "is_variant": false,
      "override_fields": [],
      "variant_count": 0,
      "source_recipe_count": 1,
      "archived_at": null,
      "updated_at": "2026-03-24T14:20:00.000000",
      "ingredients": [],
      "steps": [],
      "nutrition_summary": {
        "total_calories": 1004.0,
        "calories_per_serving": 251.0,
        "coverage_status": "complete",
        "matched_ingredient_count": 2,
        "unmatched_ingredient_count": 0,
        "unmatched_ingredients": [],
        "last_calculated_at": "2026-03-24T14:20:00.000000"
      }
    }
    """.data(using: .utf8)!

    let itemJSON = """
    {
      "item_id": "nutrition-1",
      "name": "Butter",
      "normalized_name": "butter",
      "reference_amount": 1,
      "reference_unit": "tbsp",
      "calories": 102,
      "notes": ""
    }
    """.data(using: .utf8)!

    let recipe = try SimmerSmithJSONCoding.makeDecoder().decode(RecipeSummary.self, from: recipeJSON)
    let item = try SimmerSmithJSONCoding.makeDecoder().decode(NutritionItem.self, from: itemJSON)

    #expect(recipe.nutritionSummary?.caloriesPerServing == 251.0)
    #expect(recipe.nutritionSummary?.coverageStatus == "complete")
    #expect(item.referenceUnit == "tbsp")
    #expect(item.calories == 102)
}

@Test
func decoderHandlesAssistantThreadPayload() throws {
    let json = """
    {
      "thread_id": "thread-1",
      "title": "Recipe Help",
      "preview": "Make me a better waffle recipe",
      "created_at": "2026-03-28T18:30:00.000000",
      "updated_at": "2026-03-28T18:31:00.000000",
      "messages": [
        {
          "message_id": "message-1",
          "thread_id": "thread-1",
          "role": "assistant",
          "status": "completed",
          "content_markdown": "Here is a recipe draft.",
          "recipe_draft": {
            "name": "Whole Wheat Waffles",
            "meal_type": "breakfast",
            "cuisine": "American",
            "servings": 4,
            "ingredients": [],
            "steps": []
          },
          "attached_recipe_id": null,
          "created_at": "2026-03-28T18:31:00.000000",
          "completed_at": "2026-03-28T18:31:05.000000",
          "error": ""
        }
      ]
    }
    """.data(using: .utf8)!

    let thread = try SimmerSmithJSONCoding.makeDecoder().decode(AssistantThread.self, from: json)
    #expect(thread.title == "Recipe Help")
    #expect(thread.messages.count == 1)
    #expect(thread.messages.first?.recipeDraft?.name == "Whole Wheat Waffles")
}
