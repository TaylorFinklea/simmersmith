import Foundation
import SimmerSmithKit

extension AppState {
    func searchBaseIngredients(
        query: String = "",
        limit: Int = 20,
        includeArchived: Bool = false,
        provisionalOnly: Bool = false,
        withPreferences: Bool = false,
        withVariations: Bool = false,
        includeProductLike: Bool = false
    ) async throws -> [BaseIngredient] {
        try await apiClient.fetchBaseIngredients(
            query: query,
            limit: limit,
            includeArchived: includeArchived,
            provisionalOnly: provisionalOnly,
            withPreferences: withPreferences,
            withVariations: withVariations,
            includeProductLike: includeProductLike
        )
    }

    func fetchIngredientVariations(baseIngredientID: String) async throws -> [IngredientVariation] {
        try await apiClient.fetchIngredientVariations(baseIngredientID: baseIngredientID)
    }

    func fetchBaseIngredientDetail(baseIngredientID: String) async throws -> BaseIngredientDetail {
        try await apiClient.fetchBaseIngredientDetail(baseIngredientID: baseIngredientID)
    }

    func createBaseIngredient(
        name: String,
        normalizedName: String? = nil,
        category: String = "",
        defaultUnit: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordID: String = "",
        sourceURL: String = "",
        provisional: Bool = false,
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil
    ) async throws -> BaseIngredient {
        try await apiClient.createBaseIngredient(
            name: name,
            normalizedName: normalizedName,
            category: category,
            defaultUnit: defaultUnit,
            notes: notes,
            sourceName: sourceName,
            sourceRecordId: sourceRecordID,
            sourceURL: sourceURL,
            provisional: provisional,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
    }

    func updateBaseIngredient(
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
        category: String = "",
        defaultUnit: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordID: String = "",
        sourceURL: String = "",
        provisional: Bool = false,
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil
    ) async throws -> BaseIngredient {
        try await apiClient.updateBaseIngredient(
            baseIngredientID: baseIngredientID,
            name: name,
            normalizedName: normalizedName,
            category: category,
            defaultUnit: defaultUnit,
            notes: notes,
            sourceName: sourceName,
            sourceRecordId: sourceRecordID,
            sourceURL: sourceURL,
            provisional: provisional,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
    }

    func archiveBaseIngredient(baseIngredientID: String) async throws -> BaseIngredient {
        try await apiClient.archiveBaseIngredient(baseIngredientID: baseIngredientID)
    }

    func mergeBaseIngredient(sourceID: String, targetID: String) async throws -> BaseIngredient {
        try await apiClient.mergeBaseIngredient(sourceID: sourceID, targetID: targetID)
    }

    func createIngredientVariation(
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
        brand: String = "",
        upc: String = "",
        packageSizeAmount: Double? = nil,
        packageSizeUnit: String = "",
        countPerPackage: Double? = nil,
        productUrl: String = "",
        retailerHint: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordID: String = "",
        sourceURL: String = "",
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil
    ) async throws -> IngredientVariation {
        try await apiClient.createIngredientVariation(
            baseIngredientID: baseIngredientID,
            name: name,
            normalizedName: normalizedName,
            brand: brand,
            upc: upc,
            packageSizeAmount: packageSizeAmount,
            packageSizeUnit: packageSizeUnit,
            countPerPackage: countPerPackage,
            productUrl: productUrl,
            retailerHint: retailerHint,
            notes: notes,
            sourceName: sourceName,
            sourceRecordId: sourceRecordID,
            sourceURL: sourceURL,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
    }

    func updateIngredientVariation(
        ingredientVariationID: String,
        baseIngredientID: String,
        name: String,
        normalizedName: String? = nil,
        brand: String = "",
        upc: String = "",
        packageSizeAmount: Double? = nil,
        packageSizeUnit: String = "",
        countPerPackage: Double? = nil,
        productUrl: String = "",
        retailerHint: String = "",
        notes: String = "",
        sourceName: String = "",
        sourceRecordID: String = "",
        sourceURL: String = "",
        active: Bool = true,
        nutritionReferenceAmount: Double? = nil,
        nutritionReferenceUnit: String = "",
        calories: Double? = nil
    ) async throws -> IngredientVariation {
        try await apiClient.updateIngredientVariation(
            ingredientVariationID: ingredientVariationID,
            baseIngredientID: baseIngredientID,
            name: name,
            normalizedName: normalizedName,
            brand: brand,
            upc: upc,
            packageSizeAmount: packageSizeAmount,
            packageSizeUnit: packageSizeUnit,
            countPerPackage: countPerPackage,
            productUrl: productUrl,
            retailerHint: retailerHint,
            notes: notes,
            sourceName: sourceName,
            sourceRecordId: sourceRecordID,
            sourceURL: sourceURL,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
    }

    func archiveIngredientVariation(ingredientVariationID: String) async throws -> IngredientVariation {
        try await apiClient.archiveIngredientVariation(ingredientVariationID: ingredientVariationID)
    }

    func mergeIngredientVariation(sourceID: String, targetID: String) async throws -> IngredientVariation {
        try await apiClient.mergeIngredientVariation(sourceID: sourceID, targetID: targetID)
    }

    func resolveIngredient(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
        try await apiClient.resolveIngredient(ingredient)
    }

    func refreshIngredientPreferences() async {
        guard hasSavedConnection else { return }
        do {
            ingredientPreferences = try await apiClient.fetchIngredientPreferences()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func upsertIngredientPreference(
        preferenceID: String? = nil,
        baseIngredientID: String,
        preferredVariationID: String? = nil,
        preferredBrand: String = "",
        choiceMode: String = "preferred",
        active: Bool = true,
        notes: String = "",
        rank: Int = 1
    ) async throws -> IngredientPreference {
        let preference = try await apiClient.upsertIngredientPreference(
            preferenceID: preferenceID,
            baseIngredientID: baseIngredientID,
            preferredVariationID: preferredVariationID,
            preferredBrand: preferredBrand,
            choiceMode: choiceMode,
            active: active,
            notes: notes,
            rank: rank
        )
        if let index = ingredientPreferences.firstIndex(where: { $0.preferenceId == preference.preferenceId }) {
            ingredientPreferences[index] = preference
        } else {
            ingredientPreferences.append(preference)
            // Sort by base ingredient name, then by rank (primary first).
            ingredientPreferences.sort { lhs, rhs in
                let nameOrder = lhs.baseIngredientName.localizedCaseInsensitiveCompare(rhs.baseIngredientName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.rank < rhs.rank
            }
        }
        return preference
    }

    func saveIngredientNutritionMatch(
        ingredientName: String,
        normalizedName: String?,
        nutritionItemID: String
    ) async throws -> IngredientNutritionMatch {
        try await apiClient.saveIngredientNutritionMatch(
            ingredientName: ingredientName,
            normalizedName: normalizedName,
            nutritionItemID: nutritionItemID
        )
    }
}
