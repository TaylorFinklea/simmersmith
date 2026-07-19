#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdRecords
import HouseholdSync
import SimmerSmithKit

private let ingredientMigrationScope = "ingredients"

/// A deferred migration advances the cached-session tail only when its receipt boundary is
/// complete. Retryable outcomes intentionally leave the same stage claimable on the next
/// successful reconciliation.
enum DeferredMigrationCompletion: Equatable {
    case complete
    case retryable
}

private enum DeferredMigrationPersistenceError: Error {
    case writeRejected
}

@MainActor
struct IngredientMigrationRunner {
    let hasReceipt: () -> Bool
    let fetch: () async throws -> IngredientMigrationExport
    let save: (HouseholdRecordValue) throws -> Void
    let drain: () async throws -> Void
    let saveReceipt: () throws -> Void

    func run() async -> DeferredMigrationCompletion {
        guard !hasReceipt() else { return .complete }

        let export: IngredientMigrationExport
        let records: (bases: [HouseholdRecordValue], variations: [HouseholdRecordValue])
        do {
            export = try await fetch()
            records = try IngredientMigrationRecordMapper.records(from: export)
            for record in records.bases {
                try save(record)
            }
            for record in records.variations {
                try save(record)
            }
            try await drain()
        } catch {
            return .retryable
        }

        do {
            try saveReceipt()
        } catch {
            return .retryable
        }
        try? await drain()
        return .complete
    }
}

private enum IngredientMigrationMappingError: Error {
    case unsupportedSchema
    case countMismatch
    case emptyID
    case duplicateID
    case danglingVariation
}

private enum IngredientMigrationRecordMapper {
    static func records(
        from export: IngredientMigrationExport
    ) throws -> (bases: [HouseholdRecordValue], variations: [HouseholdRecordValue]) {
        guard export.schemaVersion == 1 else {
            throw IngredientMigrationMappingError.unsupportedSchema
        }
        guard export.baseIngredientCount == export.baseIngredients.count,
              export.ingredientVariationCount == export.ingredientVariations.count else {
            throw IngredientMigrationMappingError.countMismatch
        }

        let baseIDs = export.baseIngredients.map(\.baseIngredientId)
        let variationIDs = export.ingredientVariations.map(\.ingredientVariationId)
        guard baseIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              variationIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw IngredientMigrationMappingError.emptyID
        }
        guard Set(baseIDs).count == baseIDs.count,
              Set(variationIDs).count == variationIDs.count else {
            throw IngredientMigrationMappingError.duplicateID
        }
        let ownedBaseIDs = Set(baseIDs)
        guard export.ingredientVariations.allSatisfy({ ownedBaseIDs.contains($0.baseIngredientId) }) else {
            throw IngredientMigrationMappingError.danglingVariation
        }

        return (
            bases: export.baseIngredients.map(baseRecord),
            variations: export.ingredientVariations.map(variationRecord)
        )
    }

    private static func baseRecord(_ row: BaseIngredientMigrationRow) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "name": .string(row.name),
            "normalizedName": .string(row.normalizedName),
            "submissionStatus": .string(row.submissionStatus),
            "category": .string(row.category),
            "defaultUnit": .string(row.defaultUnit),
            "notes": .string(row.notes),
            "sourceName": .string(row.sourceName),
            "sourceRecordID": .string(row.sourceRecordId),
            "sourceURL": .string(row.sourceUrl),
            "sourcePayloadJSON": .string(row.sourcePayloadJson),
            "overridePayloadJSON": .string(row.overridePayloadJson),
            "provisional": .bool(row.provisional),
            "active": .bool(row.active),
            "nutritionReferenceUnit": .string(row.nutritionReferenceUnit),
            "createdAt": .date(row.createdAt),
            "updatedAt": .date(row.updatedAt),
        ]
        assign(row.archivedAt, to: "archivedAt", in: &scalars)
        assign(row.nutritionReferenceAmount, to: "nutritionReferenceAmount", in: &scalars)
        assign(row.calories, to: "calories", in: &scalars)
        assign(row.proteinG, to: "proteinG", in: &scalars)
        assign(row.carbsG, to: "carbsG", in: &scalars)
        assign(row.fatG, to: "fatG", in: &scalars)
        assign(row.fiberG, to: "fiberG", in: &scalars)
        var refs: [String: String] = [:]
        if let mergedIntoId = row.mergedIntoId {
            refs["mergedIntoID"] = mergedIntoId
        }
        return HouseholdRecordValue(
            type: .baseIngredient,
            recordName: row.baseIngredientId,
            scalars: scalars,
            refs: refs
        )
    }

    private static func variationRecord(
        _ row: IngredientVariationMigrationRow
    ) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "name": .string(row.name),
            "normalizedName": .string(row.normalizedName),
            "brand": .string(row.brand),
            "upc": .string(row.upc),
            "packageSizeUnit": .string(row.packageSizeUnit),
            "productURL": .string(row.productUrl),
            "retailerHint": .string(row.retailerHint),
            "notes": .string(row.notes),
            "sourceName": .string(row.sourceName),
            "sourceRecordID": .string(row.sourceRecordId),
            "sourceURL": .string(row.sourceUrl),
            "sourcePayloadJSON": .string(row.sourcePayloadJson),
            "overridePayloadJSON": .string(row.overridePayloadJson),
            "active": .bool(row.active),
            "nutritionReferenceUnit": .string(row.nutritionReferenceUnit),
            "createdAt": .date(row.createdAt),
            "updatedAt": .date(row.updatedAt),
        ]
        assign(row.packageSizeAmount, to: "packageSizeAmount", in: &scalars)
        assign(row.countPerPackage, to: "countPerPackage", in: &scalars)
        assign(row.archivedAt, to: "archivedAt", in: &scalars)
        assign(row.nutritionReferenceAmount, to: "nutritionReferenceAmount", in: &scalars)
        assign(row.calories, to: "calories", in: &scalars)
        assign(row.proteinG, to: "proteinG", in: &scalars)
        assign(row.carbsG, to: "carbsG", in: &scalars)
        assign(row.fatG, to: "fatG", in: &scalars)
        assign(row.fiberG, to: "fiberG", in: &scalars)
        var refs = ["baseIngredient": row.baseIngredientId]
        if let mergedIntoId = row.mergedIntoId {
            refs["mergedIntoID"] = mergedIntoId
        }
        return HouseholdRecordValue(
            type: .ingredientVariation,
            recordName: row.ingredientVariationId,
            scalars: scalars,
            refs: refs
        )
    }

    private static func assign(
        _ value: Double?,
        to key: String,
        in scalars: inout [String: ScalarValue]
    ) {
        if let value {
            scalars[key] = .double(value)
        }
    }

    private static func assign(
        _ value: Date?,
        to key: String,
        in scalars: inout [String: ScalarValue]
    ) {
        if let value {
            scalars[key] = .date(value)
        }
    }
}

@MainActor
func migrateIngredientsIfNeeded(
    session: HouseholdSession,
    apiClient: SimmerSmithAPIClient
) async -> DeferredMigrationCompletion {
    guard CachedHouseholdSystemOperationPolicy.allows(
        .migration,
        isAuthoritative: session.hasCurrentAuthority) else { return .retryable }
    let receiptID = CKRecord.ID(
        recordName: HouseholdMigrationRunner.receiptRecordName(scope: ingredientMigrationScope),
        zoneID: session.zoneID
    )
    let runner = IngredientMigrationRunner(
        hasReceipt: { session.store.record(for: receiptID) != nil },
        fetch: { try await apiClient.fetchIngredientMigrationExport() },
        save: { value in
            guard session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID)) else {
                throw DeferredMigrationPersistenceError.writeRejected
            }
        },
        drain: { try await session.engine.sendUntilDrained() },
        saveReceipt: {
            let receipt = CKRecord(
                recordType: HouseholdMigrationRunner.receiptType,
                recordID: receiptID
            )
            receipt["scope"] = ingredientMigrationScope as CKRecordValue
            guard session.engine.save(receipt) else {
                throw DeferredMigrationPersistenceError.writeRejected
            }
        }
    )
    return await runner.run()
}
#endif
