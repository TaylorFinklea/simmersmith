import Foundation
import SwiftData

// SP-A Phase 1 — the per-user PRIVATE plane's CloudKit-backed SwiftData store.
//
// This is a SEPARATE ModelConfiguration/store from the local-only cache
// (makeSimmerSmithModelContainer). Phase 0.5 proved an NSPCKC store and a custom
// CKSyncEngine-style stack coexist in one container with no token/zone clash, so the
// PRIVATE plane rides SwiftData-over-CloudKit (= NSPersistentCloudKitContainer).
//
// The CloudKit container identifier matches the app entitlement + the cktool-deployed
// schema container.

public let simmersmithPrivatePlaneContainerID = "iCloud.app.simmersmith.cloud"

public let simmersmithPrivatePlaneModelTypes: [any PersistentModel.Type] = [
    PrivateProfileSetting.self,
    PrivateDietaryGoal.self,
    PrivatePreferenceSignal.self,
    PrivateIngredientPreference.self,
    PrivateAssistantThread.self,
    PrivateAssistantMessage.self,
    PrivateMigrationReceipt.self,
]

/// Builds the PRIVATE-plane store.
///
/// - Parameter inMemory: when `true` (tests / previews) the store is ephemeral and
///   CloudKit sync is disabled (`.none`); real builds sync to the private database.
public func makeSimmerSmithPrivatePlaneContainer(inMemory: Bool = false) throws -> ModelContainer {
    let schema = Schema(simmersmithPrivatePlaneModelTypes)
    let configuration = ModelConfiguration(
        "SimmerSmithPrivate",
        schema: schema,
        isStoredInMemoryOnly: inMemory,
        allowsSave: true,
        groupContainer: .none,
        cloudKitDatabase: inMemory ? .none : .private(simmersmithPrivatePlaneContainerID)
    )
    return try ModelContainer(for: schema, configurations: [configuration])
}
