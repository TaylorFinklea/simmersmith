import CloudKit
import Foundation
import GroceryMerge
import HouseholdSync
import SimmerSmithKit
import Testing

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct IngredientsProductFlowTests {
    @Test
    func createPreferResolveLinkMergeAndResolveAgain() async throws {
        let appState = try makeAppState()
        let session = HouseholdSession(householdID: "product-flow-\(UUID().uuidString)")
        let ingredients = IngredientRepository(session: session)
        let groceries = GroceryRepository(session: session)
        let privateContainer = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let privateStore = PrivatePlaneStore(context: privateContainer.mainContext)
        let preferences = PreferenceRepository(store: privateStore)
        appState.householdSession = session
        appState.ingredientRepository = ingredients
        appState.groceryRepository = groceries
        appState.preferenceRepository = preferences

        let source = try ingredients.createBaseIngredient(
            name: "Canned Beans",
            category: "Pantry",
            defaultUnit: "can",
            provisional: true
        )
        let target = try ingredients.createBaseIngredient(
            name: "Beans",
            category: "Pantry",
            defaultUnit: "can"
        )
        let sourceVariation = try ingredients.createIngredientVariation(
            baseIngredientID: source.id,
            name: "Market Beans",
            brand: "Market"
        )
        let targetVariation = try ingredients.createIngredientVariation(
            baseIngredientID: target.id,
            name: "Market Beans",
            brand: "Market"
        )

        let savedPreference = try await appState.upsertIngredientPreference(
            baseIngredientID: source.id,
            preferredVariationID: sourceVariation.id,
            preferredBrand: "Market",
            rank: 1
        )
        #expect(savedPreference.baseIngredientName == "Canned Beans")

        let initialResolution = try await appState.resolveIngredient(
            RecipeIngredient(
                ingredientName: "Canned Beans",
                normalizedName: source.normalizedName,
                baseIngredientId: source.id,
                baseIngredientName: source.name
            )
        )
        #expect(initialResolution.baseIngredientId == source.id)
        #expect(initialResolution.ingredientVariationId == sourceVariation.id)

        let grocery = GroceryMerge.GroceryItem(
            recordName: "grocery-beans",
            weekID: "week-1",
            baseIngredientID: source.id,
            ingredientVariationID: sourceVariation.id,
            resolutionStatus: "locked",
            normalizedName: source.normalizedName,
            ingredientName: source.name,
            modifiedAt: 10
        )
        session.engine.save(GroceryCodec.makeRecord(grocery, zoneID: session.zoneID))

        let merged = try await appState.mergeBaseIngredient(sourceID: source.id, targetID: target.id)
        #expect(merged.id == target.id)
        let archivedSource = try ingredients.fetchBaseIngredientDetail(baseIngredientID: source.id).ingredient
        #expect(!archivedSource.active)

        let storedPreference = try #require(
            try privateStore.ingredientPreference(preferenceID: savedPreference.id)
        )
        #expect(storedPreference.baseIngredientID == target.id)
        #expect(storedPreference.baseIngredientName == target.name)
        #expect(storedPreference.variation == targetVariation.id)

        let groceryRecordID = CKRecord.ID(recordName: grocery.recordName, zoneID: session.zoneID)
        let groceryRecord = try #require(session.store.record(for: groceryRecordID))
        let repairedGrocery = GroceryCodec.decode(groceryRecord)
        #expect(repairedGrocery.baseIngredientID == target.id)
        #expect(repairedGrocery.ingredientVariationID == targetVariation.id)
        #expect(repairedGrocery.modifiedAt > grocery.modifiedAt)

        let finalResolution = try await appState.resolveIngredient(
            RecipeIngredient(
                ingredientName: "Beans",
                normalizedName: target.normalizedName,
                baseIngredientId: target.id,
                baseIngredientName: target.name
            )
        )
        #expect(finalResolution.baseIngredientId == target.id)
        #expect(finalResolution.ingredientVariationId == targetVariation.id)
        #expect(IngredientOwnershipPolicy.canManage(target, currentHouseholdID: session.householdID))
        #expect(!IngredientOwnershipPolicy.canManage(
            BaseIngredient(
                baseIngredientId: "public-beans",
                name: "Public Beans",
                normalizedName: "public beans",
                updatedAt: .distantPast
            ),
            currentHouseholdID: session.householdID
        ))
    }

    private func makeAppState() throws -> AppState {
        let container = try makeSimmerSmithModelContainer(inMemory: true)
        let suite = "IngredientsProductFlowTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppState(
            modelContainer: container,
            settingsStore: ConnectionSettingsStore(
                defaults: defaults,
                keychain: KeychainStore(service: suite)
            )
        )
    }
}
