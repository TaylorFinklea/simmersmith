import Foundation
import SwiftData

// SP-A Phase 1 — invariant enforcement for the per-user PRIVATE plane.
//
// CloudKit can't enforce uniqueness, so every write is an upsert keyed on the model's
// stable `recordKey`: fetch-by-key, mutate-or-insert. Singletons (profile settings per
// key, the one dietary goal) and id-keyed rows (preferences, threads, messages) all use
// the same path. This is the client-side guard the spec calls for ("singleton/keyed
// recordNames, upsert dedupe, client validation").

public struct PrivatePlaneStore {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    private func fetchFirst<T: PersistentModel>(_ predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Profile settings (singleton per key)

    @discardableResult
    public func upsertProfileSetting(key: String, value: String, updatedAt: Date = .now) throws -> PrivateProfileSetting {
        let existing: PrivateProfileSetting? = try fetchFirst(#Predicate { $0.recordKey == key })
        if let row = existing {
            row.value = value
            row.updatedAt = updatedAt
            return row
        }
        let row = PrivateProfileSetting(recordKey: key, value: value, updatedAt: updatedAt)
        context.insert(row)
        return row
    }

    public func profileSetting(key: String) throws -> PrivateProfileSetting? {
        try fetchFirst(#Predicate { $0.recordKey == key })
    }

    // MARK: Dietary goal (singleton)

    @discardableResult
    public func upsertDietaryGoal(
        goalType: String,
        dailyCalories: Int,
        proteinG: Int,
        carbsG: Int,
        fatG: Int,
        fiberG: Int,
        notes: String,
        updatedAt: Date = .now
    ) throws -> PrivateDietaryGoal {
        let key = "dietary_goal"
        if let row: PrivateDietaryGoal = try fetchFirst(#Predicate { $0.recordKey == key }) {
            row.goalType = goalType
            row.dailyCalories = dailyCalories
            row.proteinG = proteinG
            row.carbsG = carbsG
            row.fatG = fatG
            row.fiberG = fiberG
            row.notes = notes
            row.updatedAt = updatedAt
            return row
        }
        let row = PrivateDietaryGoal(
            goalType: goalType, dailyCalories: dailyCalories, proteinG: proteinG,
            carbsG: carbsG, fatG: fatG, fiberG: fiberG, notes: notes, updatedAt: updatedAt
        )
        context.insert(row)
        return row
    }

    public func dietaryGoal() throws -> PrivateDietaryGoal? {
        let key = "dietary_goal"
        return try fetchFirst(#Predicate { $0.recordKey == key })
    }

    // MARK: Preference signals (deterministic key)

    @discardableResult
    public func upsertPreferenceSignal(
        signalType: String,
        name: String,
        normalizedName: String,
        score: Double,
        active: Bool,
        updatedAt: Date = .now
    ) throws -> PrivatePreferenceSignal {
        let key = "\(signalType):\(normalizedName)"
        if let row: PrivatePreferenceSignal = try fetchFirst(#Predicate { $0.recordKey == key }) {
            row.name = name
            row.score = score
            row.active = active
            row.updatedAt = updatedAt
            return row
        }
        let row = PrivatePreferenceSignal(
            signalType: signalType, name: name, normalizedName: normalizedName,
            score: score, active: active, updatedAt: updatedAt
        )
        context.insert(row)
        return row
    }

    // MARK: Ingredient preferences (id-keyed)

    @discardableResult
    public func upsertIngredientPreference(
        preferenceID: String,
        baseIngredientID: String,
        choiceMode: String,
        rank: Int,
        active: Bool,
        brand: String,
        variation: String,
        updatedAt: Date = .now
    ) throws -> PrivateIngredientPreference {
        if let row: PrivateIngredientPreference = try fetchFirst(#Predicate { $0.recordKey == preferenceID }) {
            row.baseIngredientID = baseIngredientID
            row.choiceMode = choiceMode
            row.rank = rank
            row.active = active
            row.brand = brand
            row.variation = variation
            row.updatedAt = updatedAt
            return row
        }
        let row = PrivateIngredientPreference(
            preferenceID: preferenceID, baseIngredientID: baseIngredientID, choiceMode: choiceMode,
            rank: rank, active: active, brand: brand, variation: variation, updatedAt: updatedAt
        )
        context.insert(row)
        return row
    }

    // MARK: Assistant threads + messages

    @discardableResult
    public func upsertAssistantThread(
        threadID: String,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        linkedWeekID: String? = nil,
        archived: Bool = false
    ) throws -> PrivateAssistantThread {
        if let row: PrivateAssistantThread = try fetchFirst(#Predicate { $0.recordKey == threadID }) {
            row.title = title
            row.updatedAt = updatedAt
            row.linkedWeekID = linkedWeekID
            row.archived = archived
            return row
        }
        let row = PrivateAssistantThread(
            threadID: threadID, title: title, createdAt: createdAt,
            updatedAt: updatedAt, linkedWeekID: linkedWeekID, archived: archived
        )
        context.insert(row)
        return row
    }

    @discardableResult
    public func upsertAssistantMessage(
        messageID: String,
        thread: PrivateAssistantThread,
        role: String,
        content: String,
        createdAt: Date,
        status: String = "completed",
        attachedRecipeID: String? = nil
    ) throws -> PrivateAssistantMessage {
        if let row: PrivateAssistantMessage = try fetchFirst(#Predicate { $0.recordKey == messageID }) {
            row.role = role
            row.content = content
            row.status = status
            row.attachedRecipeID = attachedRecipeID
            row.thread = thread
            return row
        }
        let row = PrivateAssistantMessage(
            messageID: messageID, role: role, content: content, createdAt: createdAt,
            status: status, attachedRecipeID: attachedRecipeID, thread: thread
        )
        context.insert(row)
        return row
    }

    /// Messages for a thread in stable transcript order (createdAt ascending).
    public func messages(forThreadID threadID: String) throws -> [PrivateAssistantMessage] {
        let descriptor = FetchDescriptor<PrivateAssistantMessage>(
            predicate: #Predicate { $0.thread?.recordKey == threadID },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: Migration receipt (idempotency sentinel)

    /// Records a migration scope as done if not already present. Returns `true` if it
    /// created the receipt (first time), `false` if the scope was already migrated.
    @discardableResult
    public func claimMigrationScope(_ scope: String, at date: Date = .now) throws -> Bool {
        if try fetchFirst(#Predicate<PrivateMigrationReceipt> { $0.recordKey == scope }) != nil {
            return false
        }
        context.insert(PrivateMigrationReceipt(scope: scope, createdAt: date))
        return true
    }

    public func save() throws {
        try context.save()
    }
}
