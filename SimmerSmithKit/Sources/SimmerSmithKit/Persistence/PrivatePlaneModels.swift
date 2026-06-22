import Foundation
import SwiftData

// SP-A Phase 1 — per-user PRIVATE plane, synced via NSPersistentCloudKitContainer
// (SwiftData's `cloudKitDatabase: .private(...)` IS NSPCKC underneath). These @Model
// types live in the dedicated CloudKit-backed store (see PrivatePlaneContainer); the
// existing local-only cache (CacheModels) stays in its own store.
//
// CloudKit-sync rules these models MUST obey (enforced by NSPCKC, not the compiler):
//   • NO `@Attribute(.unique)` — CloudKit can't enforce uniqueness. Identity is a
//     stable `recordKey` string; uniqueness is held by fetch-before-insert upserts
//     (see PrivatePlaneStore). Hence the `#Unique` / `.unique` macro is absent here.
//   • Every non-optional stored property has a default value.
//   • Relationships are optional and carry an explicit inverse + delete rule.
//
// Field names mirror the hand-authored CKDSL types in phase0-schema.ckdb so the
// eventual migration mapping (Phase 7) is 1:1. NSPCKC generates its own CD_-prefixed
// CloudKit schema from these classes — it does NOT use those hand-authored record
// types (those serve the SHARED household zone's custom stack from Phase 2 on).
//
// The `Private` prefix disambiguates from the same-named Codable wire structs
// (DietaryGoal, IngredientPreference, AssistantThread, AssistantMessage) in this module.

@Model
public final class PrivateProfileSetting {
    public var recordKey: String = ""   // the setting key, e.g. "image_provider", "unit_system"
    public var value: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(recordKey: String = "", value: String = "", updatedAt: Date = .now) {
        self.recordKey = recordKey
        self.value = value
        self.updatedAt = updatedAt
    }
}

@Model
public final class PrivateDietaryGoal {
    // Singleton per user; `recordKey` is the fixed sentinel "dietary_goal".
    public var recordKey: String = "dietary_goal"
    public var goalType: String = "maintain"
    public var dailyCalories: Int = 0
    public var proteinG: Int = 0
    public var carbsG: Int = 0
    public var fatG: Int = 0
    public var fiberG: Int = 0
    public var notes: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(
        goalType: String = "maintain",
        dailyCalories: Int = 0,
        proteinG: Int = 0,
        carbsG: Int = 0,
        fatG: Int = 0,
        fiberG: Int = 0,
        notes: String = "",
        updatedAt: Date = .now
    ) {
        self.recordKey = "dietary_goal"
        self.goalType = goalType
        self.dailyCalories = dailyCalories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

@Model
public final class PrivatePreferenceSignal {
    // Identity is deterministic: "<signalType>:<normalizedName>" (set by the store on upsert).
    public var recordKey: String = ""
    public var signalType: String = ""
    public var name: String = ""
    public var normalizedName: String = ""
    public var score: Double = 0
    public var active: Bool = true
    public var updatedAt: Date = Date.distantPast

    public init(
        signalType: String = "",
        name: String = "",
        normalizedName: String = "",
        score: Double = 0,
        active: Bool = true,
        updatedAt: Date = .now
    ) {
        self.signalType = signalType
        self.name = name
        self.normalizedName = normalizedName
        self.score = score
        self.active = active
        self.updatedAt = updatedAt
        self.recordKey = "\(signalType):\(normalizedName)"
    }
}

@Model
public final class PrivateIngredientPreference {
    // Identity is the app's existing preferenceId.
    public var recordKey: String = ""
    public var baseIngredientID: String = ""
    /// The human-readable ingredient name (e.g. "peanuts", "shellfish"). Stored here so
    /// the allergy hard-gate has a name to match against without a catalog round-trip.
    /// NSPCKC handles this as an additive field (CloudKit schema migration is automatic).
    public var baseIngredientName: String = ""
    public var choiceMode: String = ""
    public var rank: Int = 0
    public var active: Bool = true
    public var brand: String = ""
    public var variation: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(
        preferenceID: String = "",
        baseIngredientID: String = "",
        baseIngredientName: String = "",
        choiceMode: String = "",
        rank: Int = 0,
        active: Bool = true,
        brand: String = "",
        variation: String = "",
        updatedAt: Date = .now
    ) {
        self.recordKey = preferenceID
        self.baseIngredientID = baseIngredientID
        self.baseIngredientName = baseIngredientName
        self.choiceMode = choiceMode
        self.rank = rank
        self.active = active
        self.brand = brand
        self.variation = variation
        self.updatedAt = updatedAt
    }
}

@Model
public final class PrivateAssistantThread {
    // Identity is the app's existing threadId.
    public var recordKey: String = ""
    public var title: String = ""
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast
    public var linkedWeekID: String?
    public var archived: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \PrivateAssistantMessage.thread)
    public var messages: [PrivateAssistantMessage]?

    public init(
        threadID: String = "",
        title: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        linkedWeekID: String? = nil,
        archived: Bool = false
    ) {
        self.recordKey = threadID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.linkedWeekID = linkedWeekID
        self.archived = archived
    }
}

@Model
public final class PrivateAssistantMessage {
    // Identity is the app's existing messageId.
    public var recordKey: String = ""
    public var role: String = ""
    public var content: String = ""
    public var createdAt: Date = Date.distantPast
    public var status: String = "completed"
    public var attachedRecipeID: String?
    public var thread: PrivateAssistantThread?

    public init(
        messageID: String = "",
        role: String = "",
        content: String = "",
        createdAt: Date = .now,
        status: String = "completed",
        attachedRecipeID: String? = nil,
        thread: PrivateAssistantThread? = nil
    ) {
        self.recordKey = messageID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.status = status
        self.attachedRecipeID = attachedRecipeID
        self.thread = thread
    }
}

@Model
public final class PrivateMigrationReceipt {
    // Sentinel that gates the one-time per-scope migration import (Phase 7).
    public var recordKey: String = ""   // the migration scope identifier
    public var createdAt: Date = Date.distantPast

    public init(scope: String = "", createdAt: Date = .now) {
        self.recordKey = scope
        self.createdAt = createdAt
    }
}
