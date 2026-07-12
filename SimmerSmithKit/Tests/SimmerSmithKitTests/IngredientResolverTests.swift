import Foundation
import SimmerSmithKit
import Testing

@Suite
struct IngredientResolverTests {
    private let resolver = IngredientResolver()

    @Test
    func lockedRecipeVariationShortCircuitsEveryCandidateAndPreference() {
        let ingredient = RecipeIngredient(
            ingredientName: "Custom beans",
            normalizedName: "custom beans",
            baseIngredientId: "locked-base",
            baseIngredientName: "Locked Base",
            ingredientVariationId: "locked-variation",
            ingredientVariationName: "Locked Product",
            resolutionStatus: "locked",
            quantity: 2,
            unit: "can",
            prep: "drained",
            category: "Pantry",
            notes: "keep"
        )

        let result = resolver.resolve(
            ingredient,
            publicMatch: .fixture(id: "public"),
            householdMatch: .fixture(id: "household", householdId: "home"),
            mintedHouseholdBase: .fixture(id: "minted", householdId: "home"),
            preferences: [.fixture(baseID: "locked-base", variationID: "preferred")],
            variations: [.fixture(id: "preferred", baseID: "locked-base")]
        )

        #expect(result.ingredientName == "Custom beans")
        #expect(result.baseIngredientId == "locked-base")
        #expect(result.ingredientVariationId == "locked-variation")
        #expect(result.resolutionStatus == "locked")
        #expect(result.quantity == 2)
        #expect(result.notes == "keep")
    }

    @Test
    func existingBaseLinkPrecedesPublicThenPublicPrecedesHouseholdAndMint() {
        let existing = resolver.resolve(
            RecipeIngredient(
                ingredientName: "Beans",
                baseIngredientId: "existing",
                baseIngredientName: "Existing Beans"
            ),
            publicMatch: .fixture(id: "public"),
            householdMatch: .fixture(id: "household", householdId: "home"),
            mintedHouseholdBase: .fixture(id: "minted", householdId: "home")
        )
        #expect(existing.baseIngredientId == "existing")
        #expect(existing.baseIngredientName == "Existing Beans")

        let publicResult = resolver.resolve(
            RecipeIngredient(ingredientName: "Beans", normalizedName: "beans"),
            publicMatch: .fixture(id: "public", name: "Public Beans"),
            householdMatch: .fixture(id: "household", name: "House Beans", householdId: "home"),
            mintedHouseholdBase: .fixture(id: "minted", name: "Minted Beans", householdId: "home")
        )
        #expect(publicResult.baseIngredientId == "public")
        #expect(publicResult.baseIngredientName == "Public Beans")
    }

    @Test
    func householdThenMintThenUnresolvedAreDeterministicFallbacks() {
        let ingredient = RecipeIngredient(ingredientName: "Beans", normalizedName: "beans")
        let household = resolver.resolve(
            ingredient,
            publicMatch: nil,
            householdMatch: .fixture(id: "household", householdId: "home"),
            mintedHouseholdBase: .fixture(id: "minted", householdId: "home")
        )
        #expect(household.baseIngredientId == "household")

        let minted = resolver.resolve(
            ingredient,
            publicMatch: nil,
            householdMatch: nil,
            mintedHouseholdBase: .fixture(id: "minted", householdId: "home")
        )
        #expect(minted.baseIngredientId == "minted")
        #expect(minted.resolutionStatus == "resolved")

        #expect(resolver.needsHouseholdBase(for: ingredient, publicMatch: nil, householdMatch: nil))
        let unresolved = resolver.resolve(ingredient)
        #expect(unresolved.baseIngredientId == nil)
        #expect(unresolved.resolutionStatus == "unresolved")
    }

    @Test
    func inactiveOrNonmatchingPublicCandidateDoesNotHideHouseholdMatch() {
        let ingredient = RecipeIngredient(ingredientName: "Beans", normalizedName: "beans")
        let inactivePublic = BaseIngredient.fixture(id: "inactive-public", active: false)
        let household = BaseIngredient.fixture(id: "household", householdId: "home")

        let inactiveResult = resolver.resolve(
            ingredient,
            publicMatch: inactivePublic,
            householdMatch: household
        )
        #expect(inactiveResult.baseIngredientId == "household")

        let wrongNamePublic = BaseIngredient(
            baseIngredientId: "wrong-public",
            name: "Lentils",
            normalizedName: "lentils",
            updatedAt: .distantPast
        )
        let wrongNameResult = resolver.resolve(
            ingredient,
            publicMatch: wrongNamePublic,
            householdMatch: household
        )
        #expect(wrongNameResult.baseIngredientId == "household")
    }

    @Test
    func preferredVariationIDThenBrandFallbackOverlayTheSelectedBase() {
        let ingredient = RecipeIngredient(ingredientName: "Beans", normalizedName: "beans")
        let base = BaseIngredient.fixture(id: "base", name: "Beans")
        let exact = IngredientVariation.fixture(
            id: "exact",
            baseID: "base",
            name: "Exact Beans",
            brand: "Exact Brand"
        )
        let brand = IngredientVariation.fixture(
            id: "brand",
            baseID: "base",
            name: "Brand Beans",
            brand: "Market Brand"
        )

        let exactResult = resolver.resolve(
            ingredient,
            publicMatch: base,
            preferences: [.fixture(baseID: "base", variationID: "exact", brand: "Market Brand")],
            variations: [brand, exact]
        )
        #expect(exactResult.ingredientVariationId == "exact")
        #expect(exactResult.resolutionStatus == "resolved")

        let brandResult = resolver.resolve(
            ingredient,
            publicMatch: base,
            preferences: [.fixture(baseID: "base", variationID: "stale", brand: "market brand")],
            variations: [brand]
        )
        #expect(brandResult.ingredientVariationId == "brand")
        #expect(brandResult.ingredientVariationName == "Brand Beans")
    }

    @Test
    func inactiveAvoidanceAndUnresolvablePreferencesPreserveRecipeCandidate() {
        let ingredient = RecipeIngredient(
            ingredientName: "Beans",
            normalizedName: "beans",
            baseIngredientId: "base",
            baseIngredientName: "Beans",
            ingredientVariationId: "recipe-choice",
            ingredientVariationName: "Recipe Choice",
            resolutionStatus: "resolved"
        )
        let variations = [IngredientVariation.fixture(id: "preferred", baseID: "base")]
        let ignored = [
            IngredientPreference.fixture(baseID: "base", variationID: "preferred", active: false),
            IngredientPreference.fixture(
                id: "avoid",
                baseID: "base",
                variationID: "preferred",
                choiceMode: "avoid"
            ),
            IngredientPreference.fixture(id: "stale", baseID: "base", variationID: "missing"),
        ]

        let result = resolver.resolve(
            ingredient,
            preferences: ignored,
            variations: variations
        )

        #expect(result.ingredientVariationId == "recipe-choice")
        #expect(result.ingredientVariationName == "Recipe Choice")
    }
}

private extension BaseIngredient {
    static func fixture(
        id: String,
        name: String = "Beans",
        householdId: String? = nil,
        active: Bool = true
    ) -> Self {
        .init(
            baseIngredientId: id,
            name: name,
            normalizedName: "beans",
            active: active,
            householdId: householdId,
            submissionStatus: householdId == nil ? "approved" : "household_only",
            updatedAt: .distantPast
        )
    }
}

private extension IngredientVariation {
    static func fixture(
        id: String,
        baseID: String,
        name: String = "Preferred Beans",
        brand: String = "Brand",
        active: Bool = true
    ) -> Self {
        .init(
            ingredientVariationId: id,
            baseIngredientId: baseID,
            name: name,
            normalizedName: name.lowercased(),
            brand: brand,
            active: active,
            updatedAt: .distantPast
        )
    }
}

private extension IngredientPreference {
    static func fixture(
        id: String = "preference",
        baseID: String,
        variationID: String?,
        brand: String = "",
        choiceMode: String = "preferred",
        active: Bool = true,
        rank: Int = 1
    ) -> Self {
        .init(
            preferenceId: id,
            baseIngredientId: baseID,
            baseIngredientName: "Beans",
            preferredVariationId: variationID,
            preferredVariationName: nil,
            preferredBrand: brand,
            choiceMode: choiceMode,
            active: active,
            notes: "",
            rank: rank,
            updatedAt: .distantPast
        )
    }
}
