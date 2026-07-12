import SimmerSmithKit

@MainActor
struct IngredientResolutionCoordinator {
    struct Sources {
        let publicBaseByID: (String) async -> BaseIngredient?
        let publicBaseByNormalizedName: (String) async -> BaseIngredient?
        let householdBaseByID: (String) -> BaseIngredient?
        let householdBaseByNormalizedName: (String) -> BaseIngredient?
        let variationByID: (String) async -> IngredientVariation?
        let mintHouseholdBase: (RecipeIngredient, String) throws -> BaseIngredient
        let variations: (String) async -> [IngredientVariation]
        let preferences: () -> [IngredientPreference]
    }

    private let resolver: IngredientResolver
    private let sources: Sources

    init(resolver: IngredientResolver = IngredientResolver(), sources: Sources) {
        self.resolver = resolver
        self.sources = sources
    }

    func resolve(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
        if ingredient.resolutionStatus == "locked",
           ingredient.ingredientVariationId?.isEmpty == false {
            return resolver.resolve(ingredient)
        }

        let normalizedName = NutritionCalculator.normalizeName(
            ingredient.normalizedName?.isEmpty == false
                ? ingredient.normalizedName ?? ingredient.ingredientName
                : ingredient.ingredientName
        )
        var publicMatch: BaseIngredient?
        var householdMatch: BaseIngredient?
        var mintedHouseholdBase: BaseIngredient?
        var variationBaseID: String?

        if let baseID = nonempty(ingredient.baseIngredientId) {
            householdMatch = sources.householdBaseByID(baseID)
            if householdMatch == nil {
                publicMatch = await sources.publicBaseByID(baseID)
            }
        } else if let variationID = nonempty(ingredient.ingredientVariationId),
                  let variation = await sources.variationByID(variationID) {
            let baseID = variation.baseIngredientId
            householdMatch = sources.householdBaseByID(baseID)
            if householdMatch == nil {
                publicMatch = await sources.publicBaseByID(baseID)
            }
            if householdMatch != nil || publicMatch != nil {
                variationBaseID = baseID
            }
        } else {
            publicMatch = await sources.publicBaseByNormalizedName(normalizedName)
            if resolver.needsHouseholdBase(
                for: ingredient,
                publicMatch: publicMatch,
                householdMatch: nil
            ) {
                householdMatch = sources.householdBaseByNormalizedName(normalizedName)
            }
            if resolver.needsHouseholdBase(
                for: ingredient,
                publicMatch: publicMatch,
                householdMatch: householdMatch
            ) {
                mintedHouseholdBase = try sources.mintHouseholdBase(ingredient, normalizedName)
            }
        }

        let baseID = nonempty(ingredient.baseIngredientId)
            ?? variationBaseID
            ?? publicMatch?.baseIngredientId
            ?? householdMatch?.baseIngredientId
            ?? mintedHouseholdBase?.baseIngredientId
        let variations: [IngredientVariation]
        if let baseID {
            variations = await sources.variations(baseID)
        } else {
            variations = []
        }
        let preferences = baseID == nil ? [] : sources.preferences()
        return resolver.resolve(
            ingredient,
            publicMatch: publicMatch,
            householdMatch: householdMatch,
            mintedHouseholdBase: mintedHouseholdBase,
            preferences: preferences,
            variations: variations
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
