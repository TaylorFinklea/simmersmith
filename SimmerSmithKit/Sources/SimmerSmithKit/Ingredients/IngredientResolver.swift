import Foundation

public struct IngredientResolver: Sendable {
    public init() {}

    public func needsHouseholdBase(
        for ingredient: RecipeIngredient,
        publicMatch: BaseIngredient?,
        householdMatch: BaseIngredient?
    ) -> Bool {
        if nonempty(ingredient.baseIngredientId) != nil
            || nonempty(ingredient.ingredientVariationId) != nil {
            return false
        }
        let normalizedName = normalizedName(for: ingredient)
        return exactActive(publicMatch, normalizedName: normalizedName) == nil
            && exactActive(householdMatch, normalizedName: normalizedName) == nil
    }

    public func resolve(
        _ ingredient: RecipeIngredient,
        publicMatch: BaseIngredient? = nil,
        householdMatch: BaseIngredient? = nil,
        mintedHouseholdBase: BaseIngredient? = nil,
        preferences: [IngredientPreference] = [],
        variations: [IngredientVariation] = []
    ) -> IngredientResolution {
        let normalizedName = normalizedName(for: ingredient)
        if ingredient.resolutionStatus == "locked",
           nonempty(ingredient.ingredientVariationId) != nil {
            return resolution(
                for: ingredient,
                normalizedName: normalizedName,
                baseID: ingredient.baseIngredientId,
                baseName: ingredient.baseIngredientName,
                variationID: ingredient.ingredientVariationId,
                variationName: ingredient.ingredientVariationName,
                status: "locked"
            )
        }

        let candidates = [publicMatch, householdMatch, mintedHouseholdBase].compactMap { $0 }
        let incomingVariation = variations.first {
            $0.ingredientVariationId == nonempty(ingredient.ingredientVariationId)
                && isActive($0)
        }

        let selectedBaseID: String?
        let selectedBaseName: String?
        if let existingBaseID = nonempty(ingredient.baseIngredientId) {
            selectedBaseID = existingBaseID
            selectedBaseName = nonempty(ingredient.baseIngredientName)
                ?? candidates.first(where: { $0.baseIngredientId == existingBaseID })?.name
        } else if let incomingVariation {
            selectedBaseID = incomingVariation.baseIngredientId
            selectedBaseName = candidates.first {
                $0.baseIngredientId == incomingVariation.baseIngredientId
            }?.name
        } else if let selected = exactActive(publicMatch, normalizedName: normalizedName)
            ?? exactActive(householdMatch, normalizedName: normalizedName)
            ?? exactActive(mintedHouseholdBase, normalizedName: normalizedName) {
            selectedBaseID = selected.baseIngredientId
            selectedBaseName = selected.name
        } else {
            selectedBaseID = nil
            selectedBaseName = nil
        }

        guard let selectedBaseID else {
            return resolution(
                for: ingredient,
                normalizedName: normalizedName,
                baseID: nil,
                baseName: nil,
                variationID: nil,
                variationName: nil,
                status: "unresolved"
            )
        }

        let activeVariations = variations.filter {
            $0.baseIngredientId == selectedBaseID && isActive($0)
        }
        let preferredVariation = preferredVariation(
            baseID: selectedBaseID,
            preferences: preferences,
            variations: activeVariations
        )
        let preservedVariationID = nonempty(ingredient.ingredientVariationId)
        let preservedVariationName = nonempty(ingredient.ingredientVariationName)

        return resolution(
            for: ingredient,
            normalizedName: normalizedName,
            baseID: selectedBaseID,
            baseName: selectedBaseName,
            variationID: preferredVariation?.ingredientVariationId ?? preservedVariationID,
            variationName: preferredVariation?.name ?? preservedVariationName,
            status: "resolved"
        )
    }

    private func preferredVariation(
        baseID: String,
        preferences: [IngredientPreference],
        variations: [IngredientVariation]
    ) -> IngredientVariation? {
        let orderedPreferences = preferences
            .filter {
                $0.baseIngredientId == baseID
                    && $0.active
                    && $0.choiceMode.caseInsensitiveCompare("preferred") == .orderedSame
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.preferenceId < $1.preferenceId
            }

        for preference in orderedPreferences {
            if let preferredID = nonempty(preference.preferredVariationId),
               let exact = variations.first(where: { $0.ingredientVariationId == preferredID }) {
                return exact
            }
            if let brand = nonempty(preference.preferredBrand),
               let brandMatch = (variations
                .filter { variation in
                    variation.brand.caseInsensitiveCompare(brand) == .orderedSame
                }
                .sorted(by: variationOrder)
                .first) {
                return brandMatch
            }
        }
        return nil
    }

    private func exactActive(
        _ candidate: BaseIngredient?,
        normalizedName: String
    ) -> BaseIngredient? {
        guard let candidate,
              candidate.active,
              candidate.archivedAt == nil,
              candidate.normalizedName == normalizedName else {
            return nil
        }
        return candidate
    }

    private func isActive(_ variation: IngredientVariation) -> Bool {
        variation.active && variation.archivedAt == nil
    }

    private func variationOrder(
        _ lhs: IngredientVariation,
        _ rhs: IngredientVariation
    ) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.ingredientVariationId < rhs.ingredientVariationId
    }

    private func normalizedName(for ingredient: RecipeIngredient) -> String {
        let supplied = ingredient.normalizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalize(supplied.isEmpty ? ingredient.ingredientName : supplied)
    }

    private func normalize(_ value: String) -> String {
        var cleaned = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "&", with: " and ")
        let scalars = cleaned.unicodeScalars.map { scalar -> Character in
            let isLower = scalar >= "a" && scalar <= "z"
            let isDigit = scalar >= "0" && scalar <= "9"
            let isSpace = scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
            return (isLower || isDigit || isSpace) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolution(
        for ingredient: RecipeIngredient,
        normalizedName: String,
        baseID: String?,
        baseName: String?,
        variationID: String?,
        variationName: String?,
        status: String
    ) -> IngredientResolution {
        IngredientResolution(
            ingredientName: ingredient.ingredientName,
            normalizedName: normalizedName,
            quantity: ingredient.quantity,
            unit: ingredient.unit,
            prep: ingredient.prep,
            category: ingredient.category,
            notes: ingredient.notes,
            baseIngredientId: baseID,
            baseIngredientName: baseName,
            ingredientVariationId: variationID,
            ingredientVariationName: variationName,
            resolutionStatus: status
        )
    }
}
