import CloudKit
import HouseholdRecords
import SimmerSmithKit
import Testing

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct IngredientMigrationTests {
    @Test
    func receiptPresentSkipsFetchSaveAndDrain() async {
        var actions: [String] = []
        let runner = IngredientMigrationRunner(
            hasReceipt: { true },
            fetch: { actions.append("fetch"); return .empty },
            save: { _ in actions.append("save") },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        await runner.run()

        #expect(actions.isEmpty)
    }

    @Test
    func fetchFailureLeavesNoRecordsOrReceipt() async {
        var actions: [String] = []
        let runner = IngredientMigrationRunner(
            hasReceipt: { false },
            fetch: { actions.append("fetch"); throw TestFailure.expected },
            save: { _ in actions.append("save") },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        await runner.run()

        #expect(actions == ["fetch"])
    }

    @Test
    func danglingVariationAbortsBeforeAnySave() async {
        var actions: [String] = []
        let export = IngredientMigrationExport(
            schemaVersion: 1,
            baseIngredientCount: 0,
            ingredientVariationCount: 1,
            baseIngredients: [],
            ingredientVariations: [.fixture(id: "variation-1", baseIngredientId: "missing")]
        )
        let runner = IngredientMigrationRunner(
            hasReceipt: { false },
            fetch: { actions.append("fetch"); return export },
            save: { _ in actions.append("save") },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        await runner.run()

        #expect(actions == ["fetch"])
    }

    @Test
    func happyPathSavesBasesThenVariationsDrainsDataThenStampsReceipt() async throws {
        var actions: [String] = []
        var rows: [HouseholdRecordValue] = []
        let export = IngredientMigrationExport(
            schemaVersion: 1,
            baseIngredientCount: 1,
            ingredientVariationCount: 1,
            baseIngredients: [.fixture()],
            ingredientVariations: [.fixture()]
        )
        let runner = IngredientMigrationRunner(
            hasReceipt: { false },
            fetch: { actions.append("fetch"); return export },
            save: { row in
                rows.append(row)
                actions.append("save:\(row.type.recordTypeName):\(row.recordName)")
            },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        await runner.run()

        #expect(actions == [
            "fetch",
            "save:BaseIngredient:base-1",
            "save:IngredientVariation:variation-1",
            "drain",
            "receipt",
            "drain",
        ])
        #expect(rows.count == 2)
        #expect(rows[0].scalars["sourcePayloadJSON"] == .string("{\"source\":1}"))
        #expect(rows[0].scalars["proteinG"] == .double(2))
        #expect(rows[0].refs["mergedIntoID"] == "base-target")
        #expect(rows[1].refs["baseIngredient"] == "base-1")
        #expect(rows[1].refs["mergedIntoID"] == "variation-target")

        let zoneID = CKRecordZone.ID(zoneName: "household-test", ownerName: CKCurrentUserDefaultName)
        let variationRecord = HouseholdRecordCodec.encode(rows[1], zoneID: zoneID)
        let baseReference = try #require(variationRecord["baseIngredient"] as? CKRecord.Reference)
        #expect(baseReference.recordID.recordName == "base-1")
        #expect(baseReference.action == .deleteSelf)
        #expect(variationRecord["mergedIntoID"] as? String == "variation-target")
    }

    @Test
    func failedDataDrainLeavesNoReceiptAndRetryUsesStableRecordNames() async {
        var actions: [String] = []
        var shouldFailDrain = true
        var receiptPresent = false
        let export = IngredientMigrationExport(
            schemaVersion: 1,
            baseIngredientCount: 1,
            ingredientVariationCount: 1,
            baseIngredients: [.fixture()],
            ingredientVariations: [.fixture()]
        )
        let runner = IngredientMigrationRunner(
            hasReceipt: { receiptPresent },
            fetch: { export },
            save: { actions.append("\($0.type.recordTypeName):\($0.recordName)") },
            drain: {
                if shouldFailDrain {
                    shouldFailDrain = false
                    throw TestFailure.expected
                }
                actions.append("drain")
            },
            saveReceipt: {
                receiptPresent = true
                actions.append("receipt")
            }
        )

        await runner.run()
        #expect(!receiptPresent)
        await runner.run()

        #expect(actions == [
            "BaseIngredient:base-1",
            "IngredientVariation:variation-1",
            "BaseIngredient:base-1",
            "IngredientVariation:variation-1",
            "drain",
            "receipt",
            "drain",
        ])
        await runner.run()
        #expect(actions.count == 7)
    }

    @Test
    func emptySuccessfulExportStillDrainsThenStamps() async {
        var actions: [String] = []
        let runner = IngredientMigrationRunner(
            hasReceipt: { false },
            fetch: { .empty },
            save: { _ in actions.append("save") },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        await runner.run()

        #expect(actions == ["drain", "receipt", "drain"])
    }

    private enum TestFailure: Error {
        case expected
    }
}

private extension IngredientMigrationExport {
    static let empty = IngredientMigrationExport(
        schemaVersion: 1,
        baseIngredientCount: 0,
        ingredientVariationCount: 0,
        baseIngredients: [],
        ingredientVariations: []
    )
}

private extension BaseIngredientMigrationRow {
    static func fixture(id: String = "base-1") -> Self {
        .init(
            baseIngredientId: id,
            name: "House spice",
            normalizedName: "house spice",
            submissionStatus: "household_only",
            category: "Spices",
            defaultUnit: "tsp",
            notes: "note",
            sourceName: "legacy",
            sourceRecordId: "source-1",
            sourceUrl: "https://example.com/base",
            sourcePayloadJson: "{\"source\":1}",
            overridePayloadJson: "{\"override\":1}",
            provisional: true,
            active: false,
            archivedAt: Date(timeIntervalSince1970: 10),
            mergedIntoId: "base-target",
            nutritionReferenceAmount: 1,
            nutritionReferenceUnit: "tsp",
            calories: 5,
            proteinG: 2,
            carbsG: 3,
            fatG: 4,
            fiberG: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}

private extension IngredientVariationMigrationRow {
    static func fixture(
        id: String = "variation-1",
        baseIngredientId: String = "base-1"
    ) -> Self {
        .init(
            ingredientVariationId: id,
            baseIngredientId: baseIngredientId,
            name: "Smoked house spice",
            normalizedName: "smoked house spice",
            brand: "Brand",
            upc: "123",
            packageSizeAmount: 2,
            packageSizeUnit: "oz",
            countPerPackage: 3,
            productUrl: "https://example.com/product",
            retailerHint: "Market",
            notes: "note",
            sourceName: "legacy",
            sourceRecordId: "source-variation",
            sourceUrl: "https://example.com/variation",
            sourcePayloadJson: "{\"source\":2}",
            overridePayloadJson: "{\"override\":2}",
            active: false,
            archivedAt: Date(timeIntervalSince1970: 11),
            mergedIntoId: "variation-target",
            nutritionReferenceAmount: 2,
            nutritionReferenceUnit: "oz",
            calories: 10,
            proteinG: 1,
            carbsG: 2,
            fatG: 3,
            fiberG: 4,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 4)
        )
    }
}
