#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge
import HouseholdRecords
import HouseholdSync
import Observation
import SimmerSmithKit

@MainActor
@Observable
final class IngredientRepository {
    private(set) var baseIngredients: [BaseIngredient] = []
    private(set) var lastSyncError: Error?

    private let session: HouseholdSession

    init(session: HouseholdSession) {
        self.session = session
    }

    @ObservationIgnored
    private lazy var revisionReloader = ObservationReloader(
        track: { [weak self] in _ = self?.session.storeRevision },
        reload: { [weak self] in self?.reload() }
    )

    func startObserving() {
        revisionReloader.start()
    }

    func reload() {
        baseIngredients = searchBaseIngredients(limit: 200)
    }

    func searchBaseIngredients(
        query: String = "",
        limit: Int = 20,
        includeArchived: Bool = false,
        provisionalOnly: Bool = false,
        withVariations: Bool = false,
        includeProductLike: Bool = false
    ) -> [BaseIngredient] {
        guard limit > 0 else { return [] }

        let activeVariationRecords = session.store
            .records(ofType: HouseholdRecordType.ingredientVariation.recordTypeName)
            .filter(isActive)
        var activeVariationCountByBase: [String: Int] = [:]
        var activeVariationsByBase: [String: [HouseholdRecordValue]] = [:]
        for record in activeVariationRecords {
            let value = HouseholdRecordCodec.decode(record, as: .ingredientVariation)
            guard let baseID = value.refs["baseIngredient"] else { continue }
            activeVariationCountByBase[baseID, default: 0] += 1
            activeVariationsByBase[baseID, default: []].append(value)
        }

        let recipeCounts = usageCounts(
            records: session.store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName),
            refKey: "baseIngredientID"
        )
        let groceryRecords = session.store.records(ofType: GroceryCodec.recordType)
        var groceryCounts: [String: Int] = [:]
        for record in groceryRecords {
            if let baseID = record["baseIngredientID"] as? String {
                groceryCounts[baseID, default: 0] += 1
            }
        }

        let normalizedQuery = GroceryNormalize.name(query)
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = session.store
            .records(ofType: HouseholdRecordType.baseIngredient.recordTypeName)
            .compactMap { record -> BaseIngredient? in
                let value = HouseholdRecordCodec.decode(record, as: .baseIngredient)
                guard includeArchived || isActive(record) else { return nil }
                guard !provisionalOnly || scalarBool(value, "provisional") else { return nil }
                let baseID = record.recordID.recordName
                if withVariations && activeVariationCountByBase[baseID, default: 0] == 0 {
                    return nil
                }
                let ingredient = decodeBaseIngredient(
                    value,
                    variationCount: activeVariationCountByBase[baseID, default: 0],
                    recipeUsageCount: recipeCounts[baseID, default: 0],
                    groceryUsageCount: groceryCounts[baseID, default: 0]
                )
                guard includeProductLike || !ingredient.productLike else { return nil }
                guard normalizedQuery.isEmpty || matches(
                    ingredient,
                    variations: activeVariationsByBase[baseID, default: []],
                    normalizedQuery: normalizedQuery,
                    rawQuery: rawQuery
                ) else { return nil }
                return ingredient
            }

        if normalizedQuery.isEmpty {
            result.sort {
                if $0.provisional != $1.provisional { return !$0.provisional }
                if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }
        } else {
            result.sort {
                searchRank($0, normalizedQuery: normalizedQuery) < searchRank($1, normalizedQuery: normalizedQuery)
            }
        }
        return Array(result.prefix(min(limit, 200)))
    }

    func fetchIngredientVariations(
        baseIngredientID: String,
        includeArchived: Bool = false
    ) -> [IngredientVariation] {
        session.store.records(ofType: HouseholdRecordType.ingredientVariation.recordTypeName)
            .compactMap { record -> IngredientVariation? in
                let value = HouseholdRecordCodec.decode(record, as: .ingredientVariation)
                guard value.refs["baseIngredient"] == baseIngredientID else { return nil }
                guard includeArchived || isActive(record) else { return nil }
                return decodeIngredientVariation(value)
            }
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.id < $1.id
            }
    }

    func fetchBaseIngredientDetail(baseIngredientID: String) throws -> BaseIngredientDetail {
        let recordID = CKRecord.ID(recordName: baseIngredientID, zoneID: session.zoneID)
        guard let record = session.store.record(for: recordID),
              record.recordType == HouseholdRecordType.baseIngredient.recordTypeName else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }

        let variations = fetchIngredientVariations(baseIngredientID: baseIngredientID)
        let usage = ingredientUsage(baseIngredientID: baseIngredientID)
        let recipeUsageCount = usageCounts(
            records: session.store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName),
            refKey: "baseIngredientID"
        )[baseIngredientID, default: 0]
        let groceryUsageCount = session.store.records(ofType: GroceryCodec.recordType)
            .filter { ($0["baseIngredientID"] as? String) == baseIngredientID }
            .count
        let ingredient = decodeBaseIngredient(
            HouseholdRecordCodec.decode(record, as: .baseIngredient),
            variationCount: variations.count,
            recipeUsageCount: recipeUsageCount,
            groceryUsageCount: groceryUsageCount
        )
        return BaseIngredientDetail(
            ingredient: ingredient,
            variations: variations,
            preference: nil,
            usage: usage
        )
    }

    @discardableResult
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
    ) throws -> BaseIngredient {
        let cleanedName = try cleanRequiredName(name)
        let normalizedName = normalized(normalizedName, fallback: cleanedName)
        if let existing = activeBaseIngredient(normalizedName: normalizedName) {
            return try fetchBaseIngredientDetail(baseIngredientID: existing.id).ingredient
        }
        let recordName = UUID().uuidString
        let now = Date()
        let value = baseIngredientValue(
            recordName: recordName,
            name: cleanedName,
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
            calories: calories,
            submissionStatus: "household_only",
            createdAt: now,
            updatedAt: now,
            archivedAt: nil,
            mergedIntoID: nil
        )
        upsertRecord(value, clearing: optionalNutritionFields(for: value))
        finishWrite()
        return try fetchBaseIngredientDetail(baseIngredientID: recordName).ingredient
    }

    @discardableResult
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
    ) throws -> BaseIngredient {
        let recordID = CKRecord.ID(recordName: baseIngredientID, zoneID: session.zoneID)
        guard let existing = session.store.record(for: recordID),
              existing.recordType == HouseholdRecordType.baseIngredient.recordTypeName else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let current = HouseholdRecordCodec.decode(existing, as: .baseIngredient)
        let value = baseIngredientValue(
            recordName: baseIngredientID,
            name: try cleanRequiredName(name),
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
            calories: calories,
            submissionStatus: scalarString(current, "submissionStatus") ?? "household_only",
            createdAt: scalarDate(current, "createdAt") ?? Date(),
            updatedAt: Date(),
            archivedAt: scalarDate(current, "archivedAt"),
            mergedIntoID: current.refs["mergedIntoID"]
        )
        upsertRecord(value, clearing: optionalNutritionFields(for: value))
        finishWrite()
        return try fetchBaseIngredientDetail(baseIngredientID: baseIngredientID).ingredient
    }

    @discardableResult
    func archiveBaseIngredient(baseIngredientID: String) throws -> BaseIngredient {
        let recordID = CKRecord.ID(recordName: baseIngredientID, zoneID: session.zoneID)
        guard let existing = session.store.record(for: recordID),
              existing.recordType == HouseholdRecordType.baseIngredient.recordTypeName else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
        let now = Date()
        existing["active"] = 0 as CKRecordValue
        existing["archivedAt"] = now as CKRecordValue
        existing["updatedAt"] = now as CKRecordValue
        session.engine.save(existing)
        finishWrite()
        return try fetchBaseIngredientDetail(baseIngredientID: baseIngredientID).ingredient
    }

    @discardableResult
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
    ) throws -> IngredientVariation {
        try requireBaseIngredient(baseIngredientID)
        let cleanedName = try cleanRequiredName(name)
        let normalizedName = normalized(normalizedName, fallback: cleanedName)
        if let existing = activeIngredientVariation(
            baseIngredientID: baseIngredientID,
            normalizedName: normalizedName
        ) {
            return existing
        }
        let recordName = UUID().uuidString
        let now = Date()
        let value = ingredientVariationValue(
            recordName: recordName,
            baseIngredientID: baseIngredientID,
            name: cleanedName,
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
            calories: calories,
            createdAt: now,
            updatedAt: now,
            archivedAt: nil,
            mergedIntoID: nil
        )
        upsertRecord(value, clearing: optionalVariationFields(for: value))
        finishWrite()
        return try requireVariation(recordName)
    }

    @discardableResult
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
    ) throws -> IngredientVariation {
        try requireBaseIngredient(baseIngredientID)
        let recordID = CKRecord.ID(recordName: ingredientVariationID, zoneID: session.zoneID)
        guard let existing = session.store.record(for: recordID),
              existing.recordType == HouseholdRecordType.ingredientVariation.recordTypeName else {
            throw IngredientRepositoryError.ingredientVariationNotFound
        }
        let current = HouseholdRecordCodec.decode(existing, as: .ingredientVariation)
        let value = ingredientVariationValue(
            recordName: ingredientVariationID,
            baseIngredientID: baseIngredientID,
            name: try cleanRequiredName(name),
            normalizedName: normalizedName,
            brand: brand,
            upc: upc,
            packageSizeAmount: packageSizeAmount,
            packageSizeUnit: packageSizeUnit,
            countPerPackage: countPerPackage,
            productUrl: productUrl,
            retailerHint: retailerHint,
            notes: notes,
            sourceName: provenance(existing: scalarString(current, "sourceName"), incoming: sourceName),
            sourceRecordID: provenance(existing: scalarString(current, "sourceRecordID"), incoming: sourceRecordID),
            sourceURL: provenance(existing: scalarString(current, "sourceURL"), incoming: sourceURL),
            active: active,
            nutritionReferenceAmount: nutritionReferenceAmount,
            nutritionReferenceUnit: nutritionReferenceUnit,
            calories: calories,
            createdAt: scalarDate(current, "createdAt") ?? Date(),
            updatedAt: Date(),
            archivedAt: scalarDate(current, "archivedAt"),
            mergedIntoID: current.refs["mergedIntoID"]
        )
        upsertRecord(value, clearing: optionalVariationFields(for: value))
        finishWrite()
        return try requireVariation(ingredientVariationID)
    }

    @discardableResult
    func archiveIngredientVariation(ingredientVariationID: String) throws -> IngredientVariation {
        let recordID = CKRecord.ID(recordName: ingredientVariationID, zoneID: session.zoneID)
        guard let existing = session.store.record(for: recordID),
              existing.recordType == HouseholdRecordType.ingredientVariation.recordTypeName else {
            throw IngredientRepositoryError.ingredientVariationNotFound
        }
        let now = Date()
        existing["active"] = 0 as CKRecordValue
        existing["archivedAt"] = now as CKRecordValue
        existing["updatedAt"] = now as CKRecordValue
        session.engine.save(existing)
        finishWrite()
        return try requireVariation(ingredientVariationID)
    }

    private func baseIngredientValue(
        recordName: String,
        name: String,
        normalizedName: String?,
        category: String,
        defaultUnit: String,
        notes: String,
        sourceName: String,
        sourceRecordID: String,
        sourceURL: String,
        provisional: Bool,
        active: Bool,
        nutritionReferenceAmount: Double?,
        nutritionReferenceUnit: String,
        calories: Double?,
        submissionStatus: String,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date?,
        mergedIntoID: String?
    ) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "name": .string(name),
            "normalizedName": .string(normalized(normalizedName, fallback: name)),
            "submissionStatus": .string(submissionStatus),
            "category": .string(clean(category)),
            "defaultUnit": .string(GroceryNormalize.unit(defaultUnit)),
            "notes": .string(clean(notes)),
            "sourceName": .string(clean(sourceName)),
            "sourceRecordID": .string(clean(sourceRecordID)),
            "sourceURL": .string(clean(sourceURL)),
            "provisional": .bool(provisional),
            "active": .bool(active),
            "nutritionReferenceUnit": .string(GroceryNormalize.unit(nutritionReferenceUnit)),
            "createdAt": .date(createdAt),
            "updatedAt": .date(updatedAt),
        ]
        if let nutritionReferenceAmount { scalars["nutritionReferenceAmount"] = .double(nutritionReferenceAmount) }
        if let calories { scalars["calories"] = .double(calories) }
        if let archivedAt { scalars["archivedAt"] = .date(archivedAt) }
        var refs: [String: String] = [:]
        if let mergedIntoID { refs["mergedIntoID"] = mergedIntoID }
        return HouseholdRecordValue(type: .baseIngredient, recordName: recordName, scalars: scalars, refs: refs)
    }

    private func ingredientVariationValue(
        recordName: String,
        baseIngredientID: String,
        name: String,
        normalizedName: String?,
        brand: String,
        upc: String,
        packageSizeAmount: Double?,
        packageSizeUnit: String,
        countPerPackage: Double?,
        productUrl: String,
        retailerHint: String,
        notes: String,
        sourceName: String,
        sourceRecordID: String,
        sourceURL: String,
        active: Bool,
        nutritionReferenceAmount: Double?,
        nutritionReferenceUnit: String,
        calories: Double?,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date?,
        mergedIntoID: String?
    ) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "name": .string(name),
            "normalizedName": .string(normalized(normalizedName, fallback: name)),
            "brand": .string(clean(brand)),
            "upc": .string(clean(upc)),
            "packageSizeUnit": .string(GroceryNormalize.unit(packageSizeUnit)),
            "productURL": .string(clean(productUrl)),
            "retailerHint": .string(clean(retailerHint)),
            "notes": .string(clean(notes)),
            "sourceName": .string(clean(sourceName)),
            "sourceRecordID": .string(clean(sourceRecordID)),
            "sourceURL": .string(clean(sourceURL)),
            "active": .bool(active),
            "nutritionReferenceUnit": .string(GroceryNormalize.unit(nutritionReferenceUnit)),
            "createdAt": .date(createdAt),
            "updatedAt": .date(updatedAt),
        ]
        if let packageSizeAmount { scalars["packageSizeAmount"] = .double(packageSizeAmount) }
        if let countPerPackage { scalars["countPerPackage"] = .double(countPerPackage) }
        if let nutritionReferenceAmount { scalars["nutritionReferenceAmount"] = .double(nutritionReferenceAmount) }
        if let calories { scalars["calories"] = .double(calories) }
        if let archivedAt { scalars["archivedAt"] = .date(archivedAt) }
        var refs = ["baseIngredient": baseIngredientID]
        if let mergedIntoID { refs["mergedIntoID"] = mergedIntoID }
        return HouseholdRecordValue(type: .ingredientVariation, recordName: recordName, scalars: scalars, refs: refs)
    }

    private func decodeBaseIngredient(
        _ value: HouseholdRecordValue,
        variationCount: Int,
        recipeUsageCount: Int,
        groceryUsageCount: Int
    ) -> BaseIngredient {
        let sourceName = scalarString(value, "sourceName") ?? ""
        return BaseIngredient(
            baseIngredientId: value.recordName,
            name: scalarString(value, "name") ?? "",
            normalizedName: scalarString(value, "normalizedName") ?? "",
            category: scalarString(value, "category") ?? "",
            defaultUnit: scalarString(value, "defaultUnit") ?? "",
            notes: scalarString(value, "notes") ?? "",
            sourceName: sourceName,
            sourceRecordId: scalarString(value, "sourceRecordID") ?? "",
            sourceUrl: scalarString(value, "sourceURL") ?? "",
            provisional: scalarBool(value, "provisional"),
            active: scalarBool(value, "active", default: true),
            nutritionReferenceAmount: scalarDouble(value, "nutritionReferenceAmount"),
            nutritionReferenceUnit: scalarString(value, "nutritionReferenceUnit") ?? "",
            calories: scalarDouble(value, "calories"),
            archivedAt: scalarDate(value, "archivedAt"),
            mergedIntoId: value.refs["mergedIntoID"],
            variationCount: variationCount,
            preferenceCount: 0,
            recipeUsageCount: recipeUsageCount,
            groceryUsageCount: groceryUsageCount,
            productLike: sourceName == "Open Food Facts",
            householdId: session.householdID,
            submissionStatus: scalarString(value, "submissionStatus") ?? "household_only",
            updatedAt: scalarDate(value, "updatedAt") ?? .distantPast
        )
    }

    private func decodeIngredientVariation(_ value: HouseholdRecordValue) -> IngredientVariation {
        IngredientVariation(
            ingredientVariationId: value.recordName,
            baseIngredientId: value.refs["baseIngredient"] ?? "",
            name: scalarString(value, "name") ?? "",
            normalizedName: scalarString(value, "normalizedName") ?? "",
            brand: scalarString(value, "brand") ?? "",
            upc: scalarString(value, "upc") ?? "",
            packageSizeAmount: scalarDouble(value, "packageSizeAmount"),
            packageSizeUnit: scalarString(value, "packageSizeUnit") ?? "",
            countPerPackage: scalarDouble(value, "countPerPackage"),
            productUrl: scalarString(value, "productURL") ?? "",
            retailerHint: scalarString(value, "retailerHint") ?? "",
            notes: scalarString(value, "notes") ?? "",
            sourceName: scalarString(value, "sourceName") ?? "",
            sourceRecordId: scalarString(value, "sourceRecordID") ?? "",
            sourceUrl: scalarString(value, "sourceURL") ?? "",
            active: scalarBool(value, "active", default: true),
            nutritionReferenceAmount: scalarDouble(value, "nutritionReferenceAmount"),
            nutritionReferenceUnit: scalarString(value, "nutritionReferenceUnit") ?? "",
            calories: scalarDouble(value, "calories"),
            archivedAt: scalarDate(value, "archivedAt"),
            mergedIntoId: value.refs["mergedIntoID"],
            updatedAt: scalarDate(value, "updatedAt") ?? .distantPast
        )
    }

    private func ingredientUsage(baseIngredientID: String) -> IngredientUsageSummary {
        let recipeNames = Dictionary(uniqueKeysWithValues: session.store
            .records(ofType: HouseholdRecordType.recipe.recordTypeName)
            .map { ($0.recordID.recordName, $0["name"] as? String ?? "") })
        var recipes: [(id: String, name: String)] = []
        var seenRecipeIDs: Set<String> = []
        for record in session.store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName) {
            let value = HouseholdRecordCodec.decode(record, as: .recipeIngredient)
            guard value.refs["baseIngredientID"] == baseIngredientID,
                  let recipeID = value.refs["recipe"],
                  seenRecipeIDs.insert(recipeID).inserted else { continue }
            recipes.append((recipeID, recipeNames[recipeID] ?? ""))
        }
        recipes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let groceries = session.store.records(ofType: GroceryCodec.recordType)
            .filter { ($0["baseIngredientID"] as? String) == baseIngredientID }
            .map { (id: $0.recordID.recordName, name: $0["ingredientName"] as? String ?? "") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return IngredientUsageSummary(
            linkedRecipeIds: recipes.map { $0.id },
            linkedRecipeNames: recipes.map { $0.name },
            linkedGroceryItemIds: groceries.map { $0.id },
            linkedGroceryNames: groceries.map { $0.name }
        )
    }

    private func usageCounts(records: [CKRecord], refKey: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for record in records {
            let type = HouseholdRecordType(recordTypeName: record.recordType)
            guard let type else { continue }
            let value = HouseholdRecordCodec.decode(record, as: type)
            if let baseID = value.refs[refKey] { result[baseID, default: 0] += 1 }
        }
        return result
    }

    private func upsertRecord(_ value: HouseholdRecordValue, clearing fieldNames: Set<String>) {
        let recordID = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: recordID) {
            HouseholdRecordCodec.apply(value, onto: existing, zoneID: session.zoneID)
            for fieldName in fieldNames { existing[fieldName] = nil }
            session.engine.save(existing)
        } else {
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
    }

    private func optionalNutritionFields(for value: HouseholdRecordValue) -> Set<String> {
        Set(["nutritionReferenceAmount", "calories"].filter { value.scalars[$0] == nil })
    }

    private func optionalVariationFields(for value: HouseholdRecordValue) -> Set<String> {
        Set(["packageSizeAmount", "countPerPackage", "nutritionReferenceAmount", "calories"]
            .filter { value.scalars[$0] == nil })
    }

    private func requireBaseIngredient(_ baseIngredientID: String) throws {
        let recordID = CKRecord.ID(recordName: baseIngredientID, zoneID: session.zoneID)
        guard session.store.record(for: recordID)?.recordType == HouseholdRecordType.baseIngredient.recordTypeName else {
            throw IngredientRepositoryError.baseIngredientNotFound
        }
    }

    private func requireVariation(_ ingredientVariationID: String) throws -> IngredientVariation {
        let recordID = CKRecord.ID(recordName: ingredientVariationID, zoneID: session.zoneID)
        guard let record = session.store.record(for: recordID),
              record.recordType == HouseholdRecordType.ingredientVariation.recordTypeName else {
            throw IngredientRepositoryError.ingredientVariationNotFound
        }
        return decodeIngredientVariation(HouseholdRecordCodec.decode(record, as: .ingredientVariation))
    }

    private func isActive(_ record: CKRecord) -> Bool {
        (record["active"] as? Int ?? 1) != 0 && record["archivedAt"] == nil
    }

    private func matches(
        _ ingredient: BaseIngredient,
        variations: [HouseholdRecordValue],
        normalizedQuery: String,
        rawQuery: String
    ) -> Bool {
        if ingredient.normalizedName.contains(normalizedQuery) { return true }
        return variations.contains { variation in
            let normalizedName = scalarString(variation, "normalizedName") ?? ""
            let brand = scalarString(variation, "brand") ?? ""
            let upc = scalarString(variation, "upc") ?? ""
            return normalizedName.contains(normalizedQuery)
                || brand.localizedCaseInsensitiveContains(rawQuery)
                || upc.localizedCaseInsensitiveContains(rawQuery)
        }
    }

    private func searchRank(
        _ ingredient: BaseIngredient,
        normalizedQuery: String
    ) -> (Int, Int, Int, Int, String, String) {
        let normalizedName = ingredient.normalizedName
        return (
            normalizedName == normalizedQuery ? 0 : 1,
            normalizedName.hasPrefix(normalizedQuery) ? 0 : 1,
            normalizedName.contains(normalizedQuery) ? 0 : 1,
            normalizedName.count,
            normalizedName,
            ingredient.id
        )
    }

    private func activeBaseIngredient(normalizedName: String) -> BaseIngredient? {
        session.store.records(ofType: HouseholdRecordType.baseIngredient.recordTypeName)
            .compactMap { record -> BaseIngredient? in
                guard isActive(record) else { return nil }
                let value = HouseholdRecordCodec.decode(record, as: .baseIngredient)
                guard scalarString(value, "normalizedName") == normalizedName else { return nil }
                return decodeBaseIngredient(value, variationCount: 0, recipeUsageCount: 0, groceryUsageCount: 0)
            }
            .sorted { $0.id < $1.id }
            .first
    }

    private func activeIngredientVariation(
        baseIngredientID: String,
        normalizedName: String
    ) -> IngredientVariation? {
        session.store.records(ofType: HouseholdRecordType.ingredientVariation.recordTypeName)
            .compactMap { record -> IngredientVariation? in
                guard isActive(record) else { return nil }
                let value = HouseholdRecordCodec.decode(record, as: .ingredientVariation)
                guard value.refs["baseIngredient"] == baseIngredientID,
                      scalarString(value, "normalizedName") == normalizedName else { return nil }
                return decodeIngredientVariation(value)
            }
            .sorted { $0.id < $1.id }
            .first
    }

    private func provenance(existing: String?, incoming: String) -> String {
        let current = clean(existing ?? "")
        return current.isEmpty ? clean(incoming) : current
    }

    private func cleanRequiredName(_ value: String) throws -> String {
        let cleaned = clean(value)
        guard !cleaned.isEmpty else { throw IngredientRepositoryError.emptyName }
        return cleaned
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ value: String?, fallback: String) -> String {
        let candidate = value.map(clean) ?? ""
        return GroceryNormalize.name(candidate.isEmpty ? fallback : candidate)
    }

    private func scalarString(_ value: HouseholdRecordValue, _ key: String) -> String? {
        if case .string(let result) = value.scalars[key] { return result }
        return nil
    }

    private func scalarDouble(_ value: HouseholdRecordValue, _ key: String) -> Double? {
        if case .double(let result) = value.scalars[key] { return result }
        return nil
    }

    private func scalarDate(_ value: HouseholdRecordValue, _ key: String) -> Date? {
        if case .date(let result) = value.scalars[key] { return result }
        return nil
    }

    private func scalarBool(_ value: HouseholdRecordValue, _ key: String, default defaultValue: Bool = false) -> Bool {
        if case .bool(let result) = value.scalars[key] { return result }
        return defaultValue
    }

    private func finishWrite() {
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[IngredientRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }
}

enum IngredientRepositoryError: Error, Equatable {
    case emptyName
    case baseIngredientNotFound
    case ingredientVariationNotFound
}
#endif
