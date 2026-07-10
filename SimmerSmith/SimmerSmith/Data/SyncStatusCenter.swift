#if canImport(CloudKit)
import Foundation
import Observation
import HouseholdSync

// simmersmith-qrt: the app-side home for CloudKit sync visibility. `HouseholdSession` feeds
// this from the engine-level `onSyncError`/`onStoreChanged`/`onRecordSaved` callbacks and from
// `AppState+Sharing`'s participant post-accept fetch; `SettingsView` (the "iCloud Sync" row +
// `SyncStatusDetailView`) and the main-UI banner read the derived output. All the actual
// severity/copy logic lives in the pure `SyncStatusDerivation` (SimmerSmithCloudKit) — this
// class is just the mutable holder + DI seam, mirroring the `@MainActor @Observable`
// repositories (e.g. `GuestRepository`) it sits alongside.
@MainActor
@Observable
final class SyncStatusCenter {

    // MARK: - Observable state

    private(set) var inputs = SyncStatusInputs()

    /// The derived status — recomputed on read, not cached, since it's a cheap pure function
    /// of `inputs`.
    var derivation: SyncStatusDerivation {
        SyncStatusDerivation.derive(from: inputs)
    }

    // MARK: - Mutators

    /// An engine-level save failure (`HouseholdSyncEngine.onSyncError`).
    func recordFailure(_ failure: SyncFailure) {
        inputs.lastFailure = failure
        inputs.lastFailureAt = Date()
    }

    /// A record finished saving successfully (`HouseholdSyncEngine.onRecordSaved`).
    /// simmersmith-ioj policy (b): the recovery path for a PERMANENT failure — which
    /// `recordSyncSuccess` above deliberately no longer clears — is the SAME record later
    /// saving successfully (the user edits it again after the underlying cause is fixed,
    /// e.g. re-signing into iCloud or freeing up storage). Only clears the failure slot when
    /// the record name matches; an unrelated record saving cleanly says nothing about it.
    func recordSaveSucceeded(recordName: String) {
        guard inputs.lastFailure?.recordName == recordName else { return }
        inputs.lastFailure = nil
        inputs.lastFailureAt = nil
    }

    /// A sync cycle completed with nothing outstanding. simmersmith-ioj: a clean tick is only
    /// evidence a TRANSIENT failure is behind us — CKSyncEngine re-enqueues those itself, so
    /// "nothing pending" again means the retry landed. A PERMANENT failure (quota/auth/permission)
    /// is BY DESIGN never re-enqueued, so a clean tick proves nothing about it and must NOT clear
    /// it; it persists until the same record saves successfully (`recordSaveSucceeded` below). The
    /// actual transient-vs-permanent rule lives in the pure `SyncStatusDerivation.failureAfterCleanSync`
    /// (host-testable) — this stays a dumb holder that just calls it, per spec.
    func recordSyncSuccess(_ date: Date) {
        inputs.lastSyncedAt = date
        let retainedFailure = SyncStatusInputs.failureAfterCleanSync(inputs.lastFailure)
        inputs.lastFailure = retainedFailure
        if retainedFailure == nil {
            inputs.lastFailureAt = nil
        }
        // simmersmith-qrt (adversarial fix): a `.stalled` participant-join verdict must not
        // wedge for the rest of the session. `participantInitialFetch`'s 6-attempt/~9s retry
        // budget can expire before CKSyncEngine's automatic background sync (automaticSync:
        // true) finishes propagating a freshly-shared zone — this is exactly the race the
        // retry loop exists to survive. When that later background sync lands cleanly, treat
        // it as evidence the join actually completed and clear `.stalled` to `.joined` so the
        // banner/detail text stop reporting a join that has since succeeded. Only `.stalled`
        // is cleared here — `.joining` is left alone since a clean sync tick mid-retry doesn't
        // by itself mean the owner's data (weeks) has landed.
        if inputs.participantJoin == .stalled {
            inputs.participantJoin = .joined
        }
    }

    /// Boolean-derived pending-save signal (`engine.hasPendingRecordChanges` -> 0/1). See
    /// `HouseholdSyncEngine.hasPendingRecordChanges` — no new engine API was added for this.
    func setPendingCount(_ count: Int) {
        inputs.pendingSaveCount = count
    }

    /// Participant post-accept fetch progress (`AppState+Sharing.participantInitialFetch`).
    func setParticipantJoin(_ state: ParticipantJoinState) {
        inputs.participantJoin = state
    }

    /// Sign-out / session teardown.
    func reset() {
        inputs = SyncStatusInputs()
    }
}
#endif
