import Foundation
import SimmerSmithKit
import Testing

@Test
func ingredientMigrationExportDecodesLosslessSnakeCasePayload() throws {
    let json = #"""
    {
      "schema_version": 1,
      "base_ingredient_count": 1,
      "ingredient_variation_count": 1,
      "base_ingredients": [{
        "base_ingredient_id": "base-1",
        "name": "House spice",
        "normalized_name": "house spice",
        "submission_status": "household_only",
        "category": "Spices",
        "default_unit": "tsp",
        "notes": "note",
        "source_name": "legacy",
        "source_record_id": "source-1",
        "source_url": "https://example.com/base",
        "source_payload_json": "{}",
        "override_payload_json": "{}",
        "provisional": true,
        "active": false,
        "archived_at": "2026-07-01T12:00:00Z",
        "merged_into_id": "base-target",
        "nutrition_reference_amount": 1.0,
        "nutrition_reference_unit": "tsp",
        "calories": 5.0,
        "protein_g": 2.0,
        "carbs_g": 3.0,
        "fat_g": 4.0,
        "fiber_g": 1.0,
        "created_at": "2026-07-01T10:00:00Z",
        "updated_at": "2026-07-01T11:00:00Z"
      }],
      "ingredient_variations": [{
        "ingredient_variation_id": "variation-1",
        "base_ingredient_id": "base-1",
        "name": "Smoked house spice",
        "normalized_name": "smoked house spice",
        "brand": "Brand",
        "upc": "123",
        "package_size_amount": 2.0,
        "package_size_unit": "oz",
        "count_per_package": 3.0,
        "product_url": "https://example.com/product",
        "retailer_hint": "Market",
        "notes": "note",
        "source_name": "legacy",
        "source_record_id": "source-variation",
        "source_url": "https://example.com/variation",
        "source_payload_json": "{}",
        "override_payload_json": "{}",
        "active": false,
        "archived_at": "2026-07-01T12:00:00Z",
        "merged_into_id": "variation-target",
        "nutrition_reference_amount": 2.0,
        "nutrition_reference_unit": "oz",
        "calories": 10.0,
        "protein_g": 1.0,
        "carbs_g": 2.0,
        "fat_g": 3.0,
        "fiber_g": 4.0,
        "created_at": "2026-07-01T10:00:00Z",
        "updated_at": "2026-07-01T11:00:00Z"
      }]
    }
    """#

    let export = try SimmerSmithJSONCoding.makeDecoder().decode(
        IngredientMigrationExport.self,
        from: Data(json.utf8)
    )

    #expect(export.schemaVersion == 1)
    #expect(export.baseIngredientCount == 1)
    #expect(export.ingredientVariationCount == 1)
    #expect(export.baseIngredients[0].baseIngredientId == "base-1")
    #expect(export.baseIngredients[0].sourcePayloadJson == "{}")
    #expect(export.baseIngredients[0].proteinG == 2)
    #expect(export.ingredientVariations[0].baseIngredientId == "base-1")
    #expect(export.ingredientVariations[0].ingredientVariationId == "variation-1")
    #expect(export.ingredientVariations[0].productUrl == "https://example.com/product")
    #expect(export.ingredientVariations[0].mergedIntoId == "variation-target")
}
