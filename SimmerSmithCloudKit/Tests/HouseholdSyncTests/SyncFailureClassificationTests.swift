#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// simmersmith-dab: `handleFailedSave`'s `default:` branch used to just log-and-drop every
// CKError family besides the 3 explicitly handled ones — a household edit failing with
// quotaExceeded/notAuthenticated/permissionFailure/etc. silently never synced. These tests
// exercise the pure classifier + message-naming seam it now dispatches through. (A live
// CKSyncEngine/CKContainer traps in this sandbox, so `handleFailedSave` itself — and the
// private `loadState`/`saveState` — stay compile-verified + human-gate exercised, same
// convention as `ShareRecordFilterTests`/`NonMergerRebaseTests`.)

@Test("quotaExceeded classifies as permanent and its message names the storage-full cause")
func quotaExceededIsPermanentAndNamed() {
    #expect(HouseholdSyncEngine.classifyFailure(.quotaExceeded) == .permanent)

    let message = HouseholdSyncEngine.userMessage(for: .quotaExceeded)
    #expect(message.localizedCaseInsensitiveContains("storage") || message.localizedCaseInsensitiveContains("full"))
    #expect(message.localizedCaseInsensitiveContains("icloud"))
}

@Test("network/service/rate-limit codes classify as transient (retryable)")
func networkishCodesAreTransient() {
    #expect(HouseholdSyncEngine.classifyFailure(.networkFailure) == .transient)
    #expect(HouseholdSyncEngine.classifyFailure(.serviceUnavailable) == .transient)
    #expect(HouseholdSyncEngine.classifyFailure(.requestRateLimited) == .transient)
}

@Test("auth/permission/server-rejected codes classify as permanent (won't succeed on blind retry)")
func authAndPermissionCodesArePermanent() {
    #expect(HouseholdSyncEngine.classifyFailure(.notAuthenticated) == .permanent)
    #expect(HouseholdSyncEngine.classifyFailure(.permissionFailure) == .permanent)
    #expect(HouseholdSyncEngine.classifyFailure(.serverRejectedRequest) == .permanent)
}

@Test("an unrecognized/unlikely code defaults to permanent — never silently re-enqueued forever")
func unrecognizedCodeDefaultsToPermanent() {
    // Not in the explicit transient list and not one of the named permanent examples either —
    // exercises the "anything else" default arm of the classifier.
    #expect(HouseholdSyncEngine.classifyFailure(.assetFileNotFound) == .permanent)
}
#endif
