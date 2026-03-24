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
