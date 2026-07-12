import Foundation
import SimmerSmithKit
import SwiftData
import Testing

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct IngredientResolverIntegrationTests {
    @Test
    func coordinatorUsesPublicBeforeHouseholdAndMint() async throws {
        var actions: [String] = []
        let publicBase = BaseIngredient.fixture(id: "public", name: "Public Beans")
        let coordinator = IngredientResolutionCoordinator(
            sources: .init(
                publicBaseByID: { _ in actions.append("public-id"); return nil },
                publicBaseByNormalizedName: { _ in
                    actions.append("public-name")
                    return publicBase
                },
                householdBaseByID: { _ in actions.append("household-id"); return nil },
                householdBaseByNormalizedName: { _ in
                    actions.append("household-name")
                    return .fixture(id: "household", householdID: "home")
                },
                variationByID: { _ in actions.append("variation-id"); return nil },
                mintHouseholdBase: { _, _ in
                    actions.append("mint")
                    return .fixture(id: "minted", householdID: "home")
                },
                variations: { _ in actions.append("variations"); return [] },
                preferences: { actions.append("preferences"); return [] }
            )
        )

        let result = try await coordinator.resolve(
            RecipeIngredient(ingredientName: "Beans", normalizedName: "beans")
        )

        #expect(result.baseIngredientId == "public")
        #expect(actions == ["public-name", "variations", "preferences"])
    }

    @Test
    func coordinatorFallsBackToHouseholdThenMintsAndAppliesPreference() async throws {
        var actions: [String] = []
        var household: BaseIngredient?
        let preferred = IngredientVariation.fixture(
            id: "preferred",
            baseID: "minted",
            name: "Market Beans",
            brand: "Market"
        )
        let coordinator = IngredientResolutionCoordinator(
            sources: .init(
                publicBaseByID: { _ in nil },
                publicBaseByNormalizedName: { _ in actions.append("public"); return nil },
                householdBaseByID: { _ in nil },
                householdBaseByNormalizedName: { _ in
                    actions.append("household")
                    return household
                },
                variationByID: { _ in nil },
                mintHouseholdBase: { _, _ in
                    actions.append("mint")
                    return .fixture(id: "minted", householdID: "home")
                },
                variations: { _ in actions.append("variations"); return [preferred] },
                preferences: {
                    actions.append("preferences")
                    return [.fixture(baseID: "minted", variationID: "preferred")]
                }
            )
        )

        let minted = try await coordinator.resolve(RecipeIngredient(ingredientName: "Beans"))
        #expect(minted.baseIngredientId == "minted")
        #expect(minted.ingredientVariationId == "preferred")
        #expect(actions == ["public", "household", "mint", "variations", "preferences"])

        actions = []
        household = .fixture(id: "household", householdID: "home")
        let existing = try await coordinator.resolve(RecipeIngredient(ingredientName: "Beans"))
        #expect(existing.baseIngredientId == "household")
        #expect(actions == ["public", "household", "variations", "preferences"])
    }

    @Test
    func lockedVariationDoesNotTouchAnySource() async throws {
        var sourceWasCalled = false
        let coordinator = IngredientResolutionCoordinator(
            sources: .init(
                publicBaseByID: { _ in sourceWasCalled = true; return nil },
                publicBaseByNormalizedName: { _ in sourceWasCalled = true; return nil },
                householdBaseByID: { _ in sourceWasCalled = true; return nil },
                householdBaseByNormalizedName: { _ in sourceWasCalled = true; return nil },
                variationByID: { _ in sourceWasCalled = true; return nil },
                mintHouseholdBase: { _, _ in
                    sourceWasCalled = true
                    return .fixture(id: "minted", householdID: "home")
                },
                variations: { _ in sourceWasCalled = true; return [] },
                preferences: { sourceWasCalled = true; return [] }
            )
        )

        let result = try await coordinator.resolve(
            RecipeIngredient(
                ingredientName: "Beans",
                baseIngredientId: "base",
                baseIngredientName: "Beans",
                ingredientVariationId: "locked",
                ingredientVariationName: "Locked Beans",
                resolutionStatus: "locked"
            )
        )

        #expect(result.ingredientVariationId == "locked")
        #expect(!sourceWasCalled)
    }

    @Test
    func nonlockedVariationWithoutBaseIDDerivesAndPreservesItsBase() async throws {
        let variation = IngredientVariation.fixture(
            id: "existing-variation",
            baseID: "derived-base",
            name: "Existing Beans",
            brand: "Market"
        )
        let coordinator = IngredientResolutionCoordinator(
            sources: .init(
                publicBaseByID: { _ in nil },
                publicBaseByNormalizedName: { _ in nil },
                householdBaseByID: { baseID in
                    baseID == "derived-base"
                        ? .fixture(id: baseID, householdID: "home")
                        : nil
                },
                householdBaseByNormalizedName: { _ in nil },
                variationByID: { id in id == variation.id ? variation : nil },
                mintHouseholdBase: { _, _ in .fixture(id: "minted", householdID: "home") },
                variations: { _ in [variation] },
                preferences: { [] }
            )
        )

        let result = try await coordinator.resolve(
            RecipeIngredient(
                ingredientName: "Beans",
                ingredientVariationId: variation.id,
                ingredientVariationName: variation.name,
                resolutionStatus: "resolved"
            )
        )

        #expect(result.baseIngredientId == "derived-base")
        #expect(result.ingredientVariationId == "existing-variation")
    }

    @Test
    func appStatePreferenceWritePersistsHumanReadableBaseName() async throws {
        let appState = try makeAppState()
        let session = HouseholdSession(householdID: "preference-name-\(UUID().uuidString)")
        let ingredients = IngredientRepository(session: session)
        let base = try ingredients.createBaseIngredient(name: "Black Beans")
        let privateContainer = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let store = PrivatePlaneStore(context: privateContainer.mainContext)
        let preferences = PreferenceRepository(store: store)
        appState.ingredientRepository = ingredients
        appState.preferenceRepository = preferences

        let preference = try await appState.upsertIngredientPreference(
            baseIngredientID: base.id,
            preferredBrand: "Market",
            rank: 1
        )

        #expect(preference.baseIngredientName == "Black Beans")
        let stored = try #require(try store.ingredientPreference(preferenceID: preference.id))
        #expect(stored.baseIngredientName == "Black Beans")
    }

    private func makeAppState() throws -> AppState {
        let container = try makeSimmerSmithModelContainer(inMemory: true)
        let suite = "IngredientResolverIntegrationTests-\(UUID().uuidString)"
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

private extension BaseIngredient {
    static func fixture(
        id: String,
        name: String = "Beans",
        householdID: String? = nil
    ) -> Self {
        .init(
            baseIngredientId: id,
            name: name,
            normalizedName: "beans",
            householdId: householdID,
            submissionStatus: householdID == nil ? "approved" : "household_only",
            updatedAt: .distantPast
        )
    }
}

private extension IngredientVariation {
    static func fixture(
        id: String,
        baseID: String,
        name: String,
        brand: String
    ) -> Self {
        .init(
            ingredientVariationId: id,
            baseIngredientId: baseID,
            name: name,
            normalizedName: name.lowercased(),
            brand: brand,
            updatedAt: .distantPast
        )
    }
}

private extension IngredientPreference {
    static func fixture(baseID: String, variationID: String) -> Self {
        .init(
            preferenceId: "preference",
            baseIngredientId: baseID,
            baseIngredientName: "Beans",
            preferredVariationId: variationID,
            updatedAt: .distantPast
        )
    }
}
