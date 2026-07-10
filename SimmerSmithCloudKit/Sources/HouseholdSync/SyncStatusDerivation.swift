#if canImport(CloudKit)
import Foundation

// simmersmith-qrt: sync failures were invisible — the 8 repository `lastSyncError`
// properties had zero readers, `HouseholdSyncEngine.onSyncError` had no app-side
// subscriber, and the participant post-accept fetch gave up silently. This file is the
// PURE derivation seam: given the raw signals the app already tracks (pending saves,
// last success, last engine-level failure, participant-join progress) it derives what a
// Settings row / banner should say. No side effects, no engine state, no CKSyncEngine —
// a derivation table, not a state machine (mirrors `HouseholdSyncEngine.classifyFailure`'s
// pure-function style so it stays trivially unit-testable). `SyncStatusCenter` (app
// target) owns the mutable inputs and calls into this.

/// Overall health bucket for the derived sync status.
public enum SyncSeverity: Sendable, Equatable {
    case ok
    case degraded
    case failing
}

/// Progress of the post-accept participant fetch
/// (`AppState+Sharing.participantInitialFetch`).
public enum ParticipantJoinState: Sendable, Equatable {
    /// Not in the middle of a participant join (owner, or a join that finished a while ago).
    case idle
    /// Retrying the post-accept fetch; `attempt` is 1-based, `maxAttempts` is the retry budget.
    case joining(attempt: Int, maxAttempts: Int)
    /// The retry budget ran out and the shared household still looks empty.
    case stalled
    /// The join fetch found data — participant is caught up.
    case joined
}

/// Raw inputs the derivation reads. `SyncStatusCenter` is the only writer.
public struct SyncStatusInputs: Sendable {
    public var pendingSaveCount: Int
    public var lastSyncedAt: Date?
    public var lastFailure: SyncFailure?
    public var lastFailureAt: Date?
    public var participantJoin: ParticipantJoinState

    public init(
        pendingSaveCount: Int = 0,
        lastSyncedAt: Date? = nil,
        lastFailure: SyncFailure? = nil,
        lastFailureAt: Date? = nil,
        participantJoin: ParticipantJoinState = .idle
    ) {
        self.pendingSaveCount = pendingSaveCount
        self.lastSyncedAt = lastSyncedAt
        self.lastFailure = lastFailure
        self.lastFailureAt = lastFailureAt
        self.participantJoin = participantJoin
    }

    /// simmersmith-ioj: the clean-sync-tick policy — PURE, so `SyncStatusCenter.recordSyncSuccess`
    /// can stay a dumb holder that just calls this instead of encoding the rule itself. A clean
    /// tick (nothing left pending) is only meaningful evidence for a TRANSIENT failure: CKSyncEngine
    /// re-enqueues transient saves itself (see `HouseholdSyncEngine.handleFailedSave`'s `.transient`
    /// branch), so reaching "nothing pending" again means the retry actually landed. A PERMANENT
    /// failure (quota/auth/permission — `classifyFailure`'s default branch) is BY DESIGN never
    /// re-enqueued, so a clean tick proves nothing about it — it persists across clean ticks until
    /// the SAME record saves successfully (`SyncStatusCenter.recordSaveSucceeded`, fed by
    /// `HouseholdSyncEngine.onRecordSaved`).
    public static func failureAfterCleanSync(_ failure: SyncFailure?) -> SyncFailure? {
        guard let failure else { return nil }
        switch failure.kind {
        case .transient: return nil
        case .permanent: return failure
        }
    }
}

/// The derived, user-facing sync status. Everything a Settings row or a transient banner
/// needs to render, computed once by `derive(from:)`.
public struct SyncStatusDerivation: Sendable, Equatable {
    public let severity: SyncSeverity
    /// Short line for the Settings "iCloud Sync" row.
    public let statusLine: String
    public let showsBanner: Bool
    /// Non-nil exactly when `showsBanner` is true.
    public let bannerText: String?

    public init(severity: SyncSeverity, statusLine: String, showsBanner: Bool, bannerText: String?) {
        self.severity = severity
        self.statusLine = statusLine
        self.showsBanner = showsBanner
        self.bannerText = bannerText
    }

    public static func == (lhs: SyncStatusDerivation, rhs: SyncStatusDerivation) -> Bool {
        lhs.severity == rhs.severity
            && lhs.statusLine == rhs.statusLine
            && lhs.showsBanner == rhs.showsBanner
            && lhs.bannerText == rhs.bannerText
    }

    /// Precedence (highest first) — only one state is shown at a time, so a permanent
    /// failure always wins (a household edit didn't sync is the worst thing to hide),
    /// then a stalled participant join (also user-visible-bad), then an in-progress join,
    /// then a merely-retrying transient failure, then the happy path.
    public static func derive(from inputs: SyncStatusInputs) -> SyncStatusDerivation {
        // `SyncFailure.Kind` doesn't declare `Equatable` (HouseholdSyncEngine.swift is out of
        // scope for this bead), so match by pattern rather than `==`.
        if let failure = inputs.lastFailure, case .permanent = failure.kind {
            return SyncStatusDerivation(
                severity: .failing,
                statusLine: failure.message,
                showsBanner: true,
                bannerText: failure.message
            )
        }

        if inputs.participantJoin == .stalled {
            let bannerText = "Still joining the shared household…"
            return SyncStatusDerivation(
                severity: .degraded,
                statusLine: bannerText,
                showsBanner: true,
                bannerText: bannerText
            )
        }

        if case .joining(let attempt, let maxAttempts) = inputs.participantJoin {
            return SyncStatusDerivation(
                severity: .degraded,
                statusLine: "Joining household — attempt \(attempt) of \(maxAttempts).",
                showsBanner: false,
                bannerText: nil
            )
        }

        if let failure = inputs.lastFailure, case .transient = failure.kind, inputs.pendingSaveCount > 0 {
            return SyncStatusDerivation(
                severity: .degraded,
                statusLine: "\(inputs.pendingSaveCount) change(s) waiting to sync — retrying automatically.",
                showsBanner: false,
                bannerText: nil
            )
        }

        return SyncStatusDerivation(
            severity: .ok,
            statusLine: Self.okStatusLine(lastSyncedAt: inputs.lastSyncedAt),
            showsBanner: false,
            bannerText: nil
        )
    }

    private static func okStatusLine(lastSyncedAt: Date?) -> String {
        guard let lastSyncedAt else { return "Not yet synced with iCloud." }
        return "Synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))."
    }
}
#endif
