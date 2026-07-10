#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// simmersmith-qrt: table-driven coverage of the pure sync-status derivation. No
// CKSyncEngine/CKContainer involved — every input is a plain value, matching the
// existing `SyncFailureClassificationTests` convention for this seam.

@Test("no failure, no pending saves, never synced -> ok, 'not yet synced'")
func neverSyncedIsOkWithPlaceholderLine() {
    let derivation = SyncStatusDerivation.derive(from: SyncStatusInputs())
    #expect(derivation.severity == .ok)
    #expect(derivation.statusLine == "Not yet synced with iCloud.")
    #expect(derivation.showsBanner == false)
    #expect(derivation.bannerText == nil)
}

@Test("no failure, a past success -> ok, status line names the sync time")
func pastSuccessIsOk() {
    let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(lastSyncedAt: syncedAt)
    )
    #expect(derivation.severity == .ok)
    #expect(derivation.statusLine.hasPrefix("Synced "))
    #expect(derivation.showsBanner == false)
}

@Test("transient failure with pending saves -> degraded, no banner")
func retryableFailureWithPendingIsDegradedNoBanner() {
    let failure = SyncFailure(
        recordName: "week-1", code: .networkFailure, kind: .transient,
        message: HouseholdSyncEngine.userMessage(for: .networkFailure)
    )
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(pendingSaveCount: 1, lastFailure: failure, lastFailureAt: .now)
    )
    #expect(derivation.severity == .degraded)
    #expect(derivation.statusLine.contains("waiting to sync"))
    #expect(derivation.showsBanner == false)
    #expect(derivation.bannerText == nil)
}

@Test("transient failure with NO pending saves falls through to ok (already resolved)")
func retryableFailureWithoutPendingFallsThroughToOk() {
    let failure = SyncFailure(
        recordName: "week-1", code: .networkFailure, kind: .transient,
        message: HouseholdSyncEngine.userMessage(for: .networkFailure)
    )
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(pendingSaveCount: 0, lastFailure: failure, lastFailureAt: .now)
    )
    #expect(derivation.severity == .ok)
    #expect(derivation.showsBanner == false)
}

@Test("permanent failure -> failing severity + banner naming the cause")
func permanentFailureIsFailingWithBanner() {
    let failure = SyncFailure(
        recordName: "week-1", code: .quotaExceeded, kind: .permanent,
        message: HouseholdSyncEngine.userMessage(for: .quotaExceeded)
    )
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(pendingSaveCount: 1, lastFailure: failure, lastFailureAt: .now)
    )
    #expect(derivation.severity == .failing)
    #expect(derivation.statusLine == failure.message)
    #expect(derivation.showsBanner == true)
    #expect(derivation.bannerText == failure.message)
}

@Test("permanent failure outranks an in-progress participant join")
func permanentFailureOutranksJoining() {
    let failure = SyncFailure(
        recordName: "week-1", code: .notAuthenticated, kind: .permanent,
        message: HouseholdSyncEngine.userMessage(for: .notAuthenticated)
    )
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(
            lastFailure: failure, lastFailureAt: .now,
            participantJoin: .joining(attempt: 2, maxAttempts: 6)
        )
    )
    #expect(derivation.severity == .failing)
    #expect(derivation.showsBanner == true)
}

@Test("joining -> its own status text, no banner")
func joiningHasOwnStatusTextNoBanner() {
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(participantJoin: .joining(attempt: 3, maxAttempts: 6))
    )
    #expect(derivation.severity == .degraded)
    #expect(derivation.statusLine == "Joining household — attempt 3 of 6.")
    #expect(derivation.showsBanner == false)
    #expect(derivation.bannerText == nil)
}

@Test("stalled participant join -> degraded + banner distinguishing slow-join from empty household")
func stalledJoinIsDegradedWithBanner() {
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(participantJoin: .stalled)
    )
    #expect(derivation.severity == .degraded)
    #expect(derivation.showsBanner == true)
    #expect(derivation.bannerText == "Still joining the shared household…")
}

@Test("joined clears — behaves like the ok baseline, no residual banner")
func joinedClearsToOkBaseline() {
    let syncedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let derivation = SyncStatusDerivation.derive(
        from: SyncStatusInputs(lastSyncedAt: syncedAt, participantJoin: .joined)
    )
    #expect(derivation.severity == .ok)
    #expect(derivation.statusLine.hasPrefix("Synced "))
    #expect(derivation.showsBanner == false)
    #expect(derivation.bannerText == nil)
}

// simmersmith-ioj: `failureAfterCleanSync` is the clean-sync-tick policy `SyncStatusCenter
// .recordSyncSuccess` defers to instead of unconditionally wiping `lastFailure` — a bug that let
// a permanent failure (quota/auth/permission) recorded and then immediately followed by the same
// sync event's "nothing pending" tick erase itself before the banner ever showed. Transient must
// still self-clear on a clean tick; permanent must survive it.

@Test("clean sync clears a transient failure")
func cleanSyncClearsTransientFailure() {
    let failure = SyncFailure(
        recordName: "week-1", code: .networkFailure, kind: .transient,
        message: HouseholdSyncEngine.userMessage(for: .networkFailure)
    )
    #expect(SyncStatusInputs.failureAfterCleanSync(failure) == nil)
}

@Test("clean sync does NOT clear a permanent failure")
func cleanSyncRetainsPermanentFailure() {
    let failure = SyncFailure(
        recordName: "week-1", code: .quotaExceeded, kind: .permanent,
        message: HouseholdSyncEngine.userMessage(for: .quotaExceeded)
    )
    let retained = SyncStatusInputs.failureAfterCleanSync(failure)
    #expect(retained?.recordName == failure.recordName)
    #expect(retained?.message == failure.message)
    if case .permanent = retained?.kind {
        // expected
    } else {
        Issue.record("expected the permanent failure to survive a clean sync tick")
    }
}

@Test("clean sync with no prior failure stays nil")
func cleanSyncWithNoFailureStaysNil() {
    #expect(SyncStatusInputs.failureAfterCleanSync(nil) == nil)
}
#endif
