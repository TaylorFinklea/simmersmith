#if canImport(CloudKit)
import CloudKit
import Testing
@testable import CloudKitProvisioning

// SP-C AI-3 — the PUBLIC catalog macro read. `CatalogRow.macroProjection` is the bridge between a
// published BaseIngredient/IngredientVariation CKRecord and the deterministic NutritionCalculator.
// The CloudKit queries need iCloud auth (verified on-device); the pure record→projection mapping is
// pinned here. CKRecord construction works headlessly on macOS without an iCloud account.

private func catalogRow(_ fields: [String: CKRecordValue]) -> CatalogRow {
    let id = CKRecord.ID(recordName: "row-test")
    let record = CKRecord(recordType: "BaseIngredient", recordID: id)
    record["normalizedName"] = "test" as CKRecordValue
    record["name"] = "Test" as CKRecordValue
    for (k, v) in fields { record[k] = v }
    return CatalogRow(record)
}

@Test("a full-macro row projects every field and reports hasFullMacros")
func projectsFullMacros() {
    let row = catalogRow([
        "nutrition_reference_amount": 100.0 as CKRecordValue,
        "nutrition_reference_unit": "g" as CKRecordValue,
        "calories": 165.0 as CKRecordValue,
        "protein_g": 31.0 as CKRecordValue,
        "carbs_g": 0.0 as CKRecordValue,
        "fat_g": 3.6 as CKRecordValue,
        "fiber_g": 0.0 as CKRecordValue,
    ])
    let macros = row.macroProjection
    #expect(macros?.referenceAmount == 100.0)
    #expect(macros?.referenceUnit == "g")
    #expect(macros?.calories == 165.0)
    #expect(macros?.proteinG == 31.0)
    #expect(macros?.fatG == 3.6)
    #expect(macros?.hasFullMacros == true)
}

@Test("a calories-only row (the frozen-seed reality) projects calories and is not full-macro")
func projectsCaloriesOnly() {
    let row = catalogRow([
        "nutrition_reference_amount": 100.0 as CKRecordValue,
        "nutrition_reference_unit": "g" as CKRecordValue,
        "calories": 130.0 as CKRecordValue,
    ])
    let macros = row.macroProjection
    #expect(macros?.calories == 130.0)
    #expect(macros?.referenceAmount == 100.0)
    #expect(macros?.proteinG == nil)
    #expect(macros?.hasFullMacros == false)
}

@Test("a row with no nutrition fields projects nil")
func projectsNilWhenNoNutrition() {
    let row = catalogRow([
        "category": "produce" as CKRecordValue,
    ])
    #expect(row.macroProjection == nil)
}
#endif
