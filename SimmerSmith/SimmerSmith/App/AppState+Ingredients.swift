import Foundation
import CloudKitProvisioning
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
        #if canImport(CloudKit)
        guard let repository = ingredientRepository,
              let session = householdSession else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let household = repository.searchBaseIngredients(
            query: query,
            limit: 200,
            includeArchived: includeArchived,
            provisionalOnly: provisionalOnly,
            withVariations: withVariations,
            includeProductLike: includeProductLike
        )
        var publicIngredients: [BaseIngredient] = []
        if !provisionalOnly {
            // Household collisions plus private/product filters can consume some PUBLIC rows.
            // A bounded 2x overscan preserves useful composition without draining the catalog.
            let requestedLimit = min(max(limit, 1), 200)
            let catalogLimit = min(requestedLimit * 2, 200)
            let catalog = session.catalog
            let rows = await catalog.searchBaseIngredients(query: query, limit: catalogLimit)
            var variationCounts: [String: Int] = [:]
            if withVariations {
                // Bound CloudKit fan-out to eight concurrent variation queries per batch.
                for start in stride(from: 0, to: rows.count, by: 8) {
                    let batch = Array(rows[start..<min(start + 8, rows.count)])
                    let batchCounts = await withTaskGroup(
                        of: (String, Int).self,
                        returning: [String: Int].self
                    ) { group in
                        for row in batch {
                            group.addTask {
                                let variations = await catalog.fetchIngredientVariations(
                                    approvedActiveBase: row,
                                    limit: 200
                                )
                                return (row.recordName, variations.count)
                            }
                        }
                        var counts: [String: Int] = [:]
                        for await (recordName, count) in group { counts[recordName] = count }
                        return counts
                    }
                    variationCounts.merge(batchCounts) { _, incoming in incoming }
                }
            }
            let usage = repository.ingredientUsageSnapshots(
                baseIngredientIDs: Set(rows.map(\.recordName))
            )
            for row in rows {
                let snapshot = usage[row.recordName]
                if let ingredient = IngredientRepository.publicBaseIngredient(
                    from: row,
                    variationCount: variationCounts[row.recordName, default: 0],
                    recipeUsageCount: snapshot?.recipeRowCount ?? 0,
                    groceryUsageCount: snapshot?.groceryRowCount ?? 0
                ) {
                    publicIngredients.append(ingredient)
                }
            }
        }
        return IngredientRepository.composeSearchResults(
            household: household,
            publicCatalog: publicIngredients,
            preferences: preferenceRepository?.preferences ?? [],
            query: query,
            limit: limit,
            provisionalOnly: provisionalOnly,
            withPreferences: withPreferences,
            withVariations: withVariations,
            includeProductLike: includeProductLike
        )
        #else
        return []
        #endif
    }

    func fetchIngredientVariations(baseIngredientID: String) async throws -> [IngredientVariation] {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { return [] }
        if (try? repository.fetchBaseIngredientDetail(baseIngredientID: baseIngredientID)) != nil {
            return repository.fetchIngredientVariations(baseIngredientID: baseIngredientID)
        }
        guard let session = householdSession else { throw IngredientRepositoryError.baseIngredientNotFound }
        return await session.catalog.fetchIngredientVariations(baseIngredientID: baseIngredientID, limit: 200)
            .compactMap(IngredientRepository.publicIngredientVariation(from:))
        #else
        return []
        #endif
    }

    func fetchBaseIngredientDetail(baseIngredientID: String) async throws -> BaseIngredientDetail {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let preferences = preferenceRepository?.preferences ?? []
        let preference = preferences.filter { $0.baseIngredientId == baseIngredientID }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.id < $1.id
            }.first
        if let household = try? repository.fetchBaseIngredientDetail(baseIngredientID: baseIngredientID) {
            let ingredient = IngredientRepository.composeSearchResults(
                household: [household.ingredient], publicCatalog: [], preferences: preferences,
                query: "", limit: 1, provisionalOnly: false, withPreferences: false,
                withVariations: false, includeProductLike: true
            ).first ?? household.ingredient
            return BaseIngredientDetail(
                ingredient: ingredient,
                variations: household.variations,
                preference: preference,
                usage: household.usage
            )
        }
        guard let session = householdSession else { throw IngredientRepositoryError.baseIngredientNotFound }
        guard let row = await session.catalog.resolveBaseIngredient(recordName: baseIngredientID) else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let variationRows = await session.catalog.fetchIngredientVariations(
            approvedActiveBase: row, limit: 200
        )
        let variations = variationRows.compactMap(IngredientRepository.publicIngredientVariation(from:))
        let usage = repository.ingredientUsageSnapshot(baseIngredientID: baseIngredientID)
        guard let ingredient = IngredientRepository.publicBaseIngredient(
            from: row,
            variationCount: variations.count,
            preferenceCount: preferences.filter { $0.active && $0.baseIngredientId == baseIngredientID }.count,
            recipeUsageCount: usage.recipeRowCount,
            groceryUsageCount: usage.groceryRowCount
        ) else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        return BaseIngredientDetail(
            ingredient: ingredient, variations: variations, preference: preference, usage: usage.summary
        )
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
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
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.baseIngredientNotFound }
        return try repository.createBaseIngredient(
            name: name,
            normalizedName: normalizedName,
            category: category,
            defaultUnit: defaultUnit,
            notes: notes,
            sourceName: sourceName,
            sourceRecordID: sourceRecordID,
            sourceURL: sourceURL,
            provisional: provisional,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
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
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.baseIngredientNotFound }
        return try repository.updateBaseIngredient(
            baseIngredientID: baseIngredientID,
            name: name,
            normalizedName: normalizedName,
            category: category,
            defaultUnit: defaultUnit,
            notes: notes,
            sourceName: sourceName,
            sourceRecordID: sourceRecordID,
            sourceURL: sourceURL,
            provisional: provisional,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
    }

    func archiveBaseIngredient(baseIngredientID: String) async throws -> BaseIngredient {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.baseIngredientNotFound }
        return try repository.archiveBaseIngredient(baseIngredientID: baseIngredientID)
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
    }

    func mergeBaseIngredient(sourceID: String, targetID: String) async throws -> BaseIngredient {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.baseIngredientNotFound }
        guard let preferenceRepository else { throw PreferenceRepositoryError.storeUnavailable }
        let preview = try repository.previewBaseIngredientMerge(sourceID: sourceID, targetID: targetID)
        try preferenceRepository.repointAfterIngredientMerge(
            sourceBaseIngredientID: sourceID,
            sourceBaseIngredientName: preview.source.name,
            targetBaseIngredientID: targetID,
            targetBaseIngredientName: preview.target.name,
            variationIDMap: preview.variationIDMap
        )
        let result = try repository.mergeBaseIngredientWithVariationMap(sourceID: sourceID, targetID: targetID)
        mirrorPreferencesFromRepository()
        return result.ingredient
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
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
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.baseIngredientNotFound }
        return try repository.createIngredientVariation(
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
            sourceRecordID: sourceRecordID,
            sourceURL: sourceURL,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
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
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.ingredientVariationNotFound }
        return try repository.updateIngredientVariation(
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
            sourceRecordID: sourceRecordID,
            sourceURL: sourceURL,
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories
        )
        #else
        throw IngredientRepositoryError.ingredientVariationNotFound
        #endif
    }

    func archiveIngredientVariation(ingredientVariationID: String) async throws -> IngredientVariation {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository else { throw IngredientRepositoryError.ingredientVariationNotFound }
        return try repository.archiveIngredientVariation(ingredientVariationID: ingredientVariationID)
        #else
        throw IngredientRepositoryError.ingredientVariationNotFound
        #endif
    }

    func resolveIngredient(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
        #if canImport(CloudKit)
        guard let repository = ingredientRepository,
              let session = householdSession else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let catalog = session.catalog
        let coordinator = IngredientResolutionCoordinator(
            sources: .init(
                publicBaseByID: { recordName in
                    guard let row = await catalog.resolveBaseIngredient(recordName: recordName) else {
                        return nil
                    }
                    return IngredientRepository.publicBaseIngredient(from: row)
                },
                publicBaseByNormalizedName: { normalizedName in
                    guard let row = await catalog.resolveBaseIngredient(normalizedName: normalizedName) else {
                        return nil
                    }
                    return IngredientRepository.publicBaseIngredient(from: row)
                },
                householdBaseByID: { baseID in
                    try? repository.fetchBaseIngredientDetail(baseIngredientID: baseID).ingredient
                },
                householdBaseByNormalizedName: { normalizedName in
                    repository.searchBaseIngredients(
                        query: normalizedName,
                        limit: 200,
                        includeProductLike: true
                    ).first {
                        $0.active && $0.archivedAt == nil && $0.normalizedName == normalizedName
                    }
                },
                variationByID: { variationID in
                    if let householdVariation = repository.ingredientVariation(
                        ingredientVariationID: variationID
                    ), let base = try? repository.fetchBaseIngredientDetail(
                        baseIngredientID: householdVariation.baseIngredientId
                    ).ingredient, base.active, base.archivedAt == nil {
                        return householdVariation
                    }
                    guard let row = await catalog.resolveIngredientVariation(recordName: variationID),
                          let variation = IngredientRepository.publicIngredientVariation(from: row),
                          await catalog.resolveBaseIngredient(
                            recordName: variation.baseIngredientId
                          ) != nil else {
                        return nil
                    }
                    return variation
                },
                mintHouseholdBase: { ingredient, normalizedName in
                    try repository.createBaseIngredient(
                        name: ingredient.ingredientName,
                        normalizedName: normalizedName,
                        category: ingredient.category,
                        defaultUnit: ingredient.unit,
                        notes: ingredient.notes,
                        provisional: true
                    )
                },
                variations: { baseID in
                    if (try? repository.fetchBaseIngredientDetail(baseIngredientID: baseID)) != nil {
                        return repository.fetchIngredientVariations(baseIngredientID: baseID)
                    }
                    return await catalog.fetchIngredientVariations(
                        baseIngredientID: baseID,
                        limit: 200
                    ).compactMap(IngredientRepository.publicIngredientVariation(from:))
                },
                preferences: { self.preferenceRepository?.preferences ?? [] }
            )
        )
        return try await coordinator.resolve(ingredient)
        #else
        throw IngredientRepositoryError.baseIngredientNotFound
        #endif
    }

    // SP-C slice 5 — ingredient preferences now route through PreferenceRepository
    // (private plane, NSPCKC).

    func refreshIngredientPreferences() async {
        #if canImport(CloudKit)
        if let repo = preferenceRepository {
            repo.reload()
            ingredientPreferences = repo.preferences
            return
        }
        #endif
        ingredientPreferences = []
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
        #if canImport(CloudKit)
        if let repo = preferenceRepository {
            let baseIngredientName: String
            if let household = try? ingredientRepository?.fetchBaseIngredientDetail(
                baseIngredientID: baseIngredientID
            ).ingredient {
                baseIngredientName = household.name
            } else if let session = householdSession,
                      let row = await session.catalog.resolveBaseIngredient(recordName: baseIngredientID) {
                baseIngredientName = row.name
            } else {
                throw IngredientRepositoryError.baseIngredientNotFound
            }
            let prefID = preferenceID ?? ""
            let preference = IngredientPreference(
                preferenceId: prefID,
                baseIngredientId: baseIngredientID,
                baseIngredientName: baseIngredientName,
                preferredVariationId: preferredVariationID,
                preferredBrand: preferredBrand,
                choiceMode: choiceMode,
                active: active,
                notes: notes,
                rank: rank,
                updatedAt: Date()
            )
            guard let mintedID = repo.upsert(preference) else {
                throw PreferenceRepositoryError.storeUnavailable
            }
            repo.reload()
            ingredientPreferences = repo.preferences
            return repo.preferences.first(where: { $0.preferenceId == mintedID }) ?? preference
        }
        #endif
        throw IngredientRepositoryError.baseIngredientNotFound
    }

    func saveIngredientNutritionMatch(
        ingredientName: String,
        normalizedName: String?,
        nutritionItemID: String
    ) async throws -> IngredientNutritionMatch {
        // CATALOG TRACK: storing a user's ingredient→nutrition-item match requires a small
        // manifest record on the private or household plane (IngredientNutritionMatch is
        // per-household). This is DEFERRED pending a schema decision: the match could ride
        // the existing preference/private-plane store (a new IngredientNutritionMatch
        // manifest type), or a lightweight household record. Flag this as a follow-up
        // (the UI that calls this — RecipeNutritionMatchView — is gated behind
        // `!isCloudKitOnly` already, so no CloudKit-only path is ever reached here).
        // For now, fall through to the Fly path (pre-CloudKit-session devices only).
        try await apiClient.saveIngredientNutritionMatch(
            ingredientName: ingredientName,
            normalizedName: normalizedName,
            nutritionItemID: nutritionItemID
        )
    }
}
