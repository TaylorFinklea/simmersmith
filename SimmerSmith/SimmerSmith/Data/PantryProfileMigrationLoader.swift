#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdRecords
import HouseholdSync
import OSLog
import SimmerSmithKit
import SwiftData

// SP-C slice 5 — one-time Fly→CloudKit migration of pantry items and aliases into the
// household zone, and profile/preferences into the per-user private plane. Its private
// receipt is stamped last, after the household drain, so every earlier failure is retryable.
private let pantryProfileMigrationScope = "pantry-profile"
private let log = Logger(subsystem: "app.simmersmith.cloud", category: "PantryProfileMigrationLoader")

private enum PantryProfileMigrationPersistenceError: Error {
    case householdWriteRejected
}

/// True when no private-plane upsert was dropped during the migration write phase — the
/// receipt-stamp guard is intentionally internal so the app target can pin the contract.
func pantryProfileMigrationIsComplete(droppedCount: Int) -> Bool {
    droppedCount == 0
}

struct PantryProfileMigrationPrivateWriteResult {
    let attempted: Int
    let dropped: Int
}

enum PantryProfileMigrationRunResult {
    case completed
    case retryable
    case incompletePrivateWrites(PantryProfileMigrationPrivateWriteResult)
}

/// The migration's async authority fence. Every fetch and drain returns through this runner,
/// which revalidates the exact caller-supplied session/epoch before any subsequent write.
@MainActor
struct PantryProfileMigrationRunner {
    let isCurrentAuthoritative: () -> Bool
    let hasReceipt: () -> Bool
    let fetchPantry: () async throws -> [PantryItem]
    let fetchAliases: () async throws -> [HouseholdTermAlias]
    let fetchProfile: () async throws -> ProfileSnapshot
    let fetchIngredientPreferences: () async throws -> [IngredientPreference]
    let saveHouseholdData: ([PantryItem], [HouseholdTermAlias]) throws -> Void
    let savePrivateData: (ProfileSnapshot?, [IngredientPreference], Date) -> PantryProfileMigrationPrivateWriteResult
    let drainHouseholdData: () async throws -> Void
    let stampReceipt: (Date) -> Bool

    func run() async -> PantryProfileMigrationRunResult {
        guard isCurrentAuthoritative(), !hasReceipt() else { return .retryable }

        let pantryItems: [PantryItem]
        do {
            pantryItems = try await fetchPantry()
        } catch {
            return .retryable
        }
        guard isCurrentAuthoritative() else { return .retryable }

        let aliases: [HouseholdTermAlias]
        do {
            aliases = try await fetchAliases()
        } catch {
            aliases = []
        }
        guard isCurrentAuthoritative() else { return .retryable }

        let profile: ProfileSnapshot?
        do {
            profile = try await fetchProfile()
        } catch {
            profile = nil
        }
        guard isCurrentAuthoritative() else { return .retryable }

        let preferences: [IngredientPreference]
        do {
            preferences = try await fetchIngredientPreferences()
        } catch {
            preferences = []
        }
        guard isCurrentAuthoritative() else { return .retryable }

        do {
            try saveHouseholdData(pantryItems, aliases)
        } catch {
            return .retryable
        }

        // This is the final authority check before the captured private store is touched.
        guard isCurrentAuthoritative() else { return .retryable }
        let privateWrites = savePrivateData(profile, preferences, Date())

        do {
            try await drainHouseholdData()
        } catch {
            return .retryable
        }
        guard isCurrentAuthoritative() else { return .retryable }
        guard pantryProfileMigrationIsComplete(droppedCount: privateWrites.dropped) else {
            return .incompletePrivateWrites(privateWrites)
        }

        // The receipt is the terminal private write and needs its own exact recheck.
        guard isCurrentAuthoritative(), stampReceipt(Date()) else { return .retryable }
        return .completed
    }
}

/// Pull Fly pantry/profile data into the two CloudKit planes. The AppState caller supplies
/// its exact session-and-epoch predicate; legacy callers retain the session-authority fence.
@MainActor
func migratePantryProfileIfNeeded(
    session: HouseholdSession,
    apiClient: SimmerSmithAPIClient,
    isCurrentAuthoritative: (() -> Bool)? = nil
) async {
    let isCurrent: () -> Bool = {
        CachedHouseholdSystemOperationPolicy.allows(
            .migration,
            isAuthoritative: session.hasCurrentAuthority
        ) && (isCurrentAuthoritative?() ?? true)
    }
    guard isCurrent(), let privateStore = session.privateStore else { return }

    let alreadyMigrated: Bool
    do {
        alreadyMigrated = try privateStore.fetchFirst(
            #Predicate<PrivateMigrationReceipt> { $0.recordKey == pantryProfileMigrationScope }
        ) != nil
    } catch {
        return
    }
    guard !alreadyMigrated else { return }

    let runner = PantryProfileMigrationRunner(
        isCurrentAuthoritative: isCurrent,
        hasReceipt: { false },
        fetchPantry: { try await apiClient.fetchPantryItems() },
        fetchAliases: { try await apiClient.fetchHouseholdAliases() },
        fetchProfile: { try await apiClient.fetchProfile() },
        fetchIngredientPreferences: { try await apiClient.fetchIngredientPreferences() },
        saveHouseholdData: { pantryItems, aliases in
            try savePantryProfileHouseholdData(pantryItems, aliases, session: session)
        },
        savePrivateData: { profile, preferences, now in
            savePantryProfilePrivateData(profile, preferences, store: privateStore, now: now)
        },
        drainHouseholdData: {
            try await session.engine.sendUntilDrained()
        },
        stampReceipt: { now in
            guard (try? privateStore.claimMigrationScope(pantryProfileMigrationScope, at: now)) != nil else {
                return false
            }
            return (try? privateStore.save()) != nil
        }
    )

    if case .incompletePrivateWrites(let privateWrites) = await runner.run() {
        log.error("pantry-profile migration dropped \(privateWrites.dropped, privacy: .public) of \(privateWrites.attempted, privacy: .public) private-plane upserts; receipt withheld for retry")
    }
}

@MainActor
private func savePantryProfileHouseholdData(
    _ pantryItems: [PantryItem],
    _ aliases: [HouseholdTermAlias],
    session: HouseholdSession
) throws {
    for item in pantryItems {
        let categoriesSerialized: String
        if let data = try? JSONSerialization.data(withJSONObject: item.categories),
           let string = String(data: data, encoding: .utf8) {
            categoriesSerialized = string
        } else {
            categoriesSerialized = "[]"
        }

        var scalars: [String: ScalarValue] = [
            "stapleName": .string(item.stapleName),
            "normalizedName": .string(item.normalizedName),
            "notes": .string(item.notes),
            "isActive": .bool(item.isActive),
            "typicalUnit": .string(item.typicalUnit),
            "recurringUnit": .string(item.recurringUnit),
            "recurringCadence": .string(item.recurringCadence),
            "category": .string(item.category),
            "categories": .string(categoriesSerialized),
            "createdAt": .date(item.updatedAt),
            "updatedAt": .date(item.updatedAt),
        ]
        if let quantity = item.typicalQuantity { scalars["typicalQuantity"] = .double(quantity) }
        if let quantity = item.recurringQuantity { scalars["recurringQuantity"] = .double(quantity) }
        if let date = item.lastAppliedAt { scalars["lastAppliedAt"] = .date(date) }
        if let date = item.frozenAt { scalars["frozenAt"] = .date(date) }

        let value = HouseholdRecordValue(
            type: .pantryItem,
            recordName: item.pantryItemId,
            scalars: scalars,
            refs: [:]
        )
        guard session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID)) else {
            throw PantryProfileMigrationPersistenceError.householdWriteRejected
        }
    }

    for alias in aliases {
        let value = HouseholdRecordValue(
            type: .householdTermAlias,
            recordName: RecordNames.termAlias(term: alias.term),
            scalars: [
                "term": .string(alias.term),
                "expansion": .string(alias.expansion),
                "notes": .string(alias.notes),
                "createdAt": .date(alias.updatedAt),
                "updatedAt": .date(alias.updatedAt),
            ],
            refs: [:]
        )
        guard session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID)) else {
            throw PantryProfileMigrationPersistenceError.householdWriteRejected
        }
    }
}

@MainActor
private func savePantryProfilePrivateData(
    _ profile: ProfileSnapshot?,
    _ preferences: [IngredientPreference],
    store: PrivatePlaneStore,
    now: Date
) -> PantryProfileMigrationPrivateWriteResult {
    var attempted = 0
    var dropped = 0
    if let profile {
        for key in ProfileRepository.nonAIKeys {
            guard let value = profile.settings[key] else { continue }
            attempted += 1
            do {
                try store.upsertProfileSetting(key: key, value: value, updatedAt: profile.updatedAt ?? now)
            } catch {
                dropped += 1
            }
        }
        if let goal = profile.dietaryGoal {
            attempted += 1
            do {
                try store.upsertDietaryGoal(
                    goalType: goal.goalType.rawValue,
                    dailyCalories: goal.dailyCalories,
                    proteinG: goal.proteinG,
                    carbsG: goal.carbsG,
                    fatG: goal.fatG,
                    fiberG: goal.fiberG ?? 0,
                    notes: goal.notes,
                    updatedAt: goal.updatedAt ?? now
                )
            } catch {
                dropped += 1
            }
        }
        try? store.save()
    }

    for preference in preferences {
        attempted += 1
        do {
            try store.upsertIngredientPreference(
                preferenceID: preference.preferenceId,
                baseIngredientID: preference.baseIngredientId,
                baseIngredientName: preference.baseIngredientName,
                choiceMode: preference.choiceMode,
                rank: preference.rank,
                active: preference.active,
                brand: preference.preferredBrand,
                variation: preference.preferredVariationId ?? "",
                updatedAt: preference.updatedAt
            )
        } catch {
            dropped += 1
        }
    }
    if !preferences.isEmpty {
        try? store.save()
    }
    return .init(attempted: attempted, dropped: dropped)
}

private extension PrivatePlaneStore {
    func fetchFirst<T: PersistentModel>(_ predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
#endif
