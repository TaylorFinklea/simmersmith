#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdSync
import Observation
import OSLog
import SwiftUI

struct HouseholdZoneRecoveryAuthoritySnapshot: Equatable, Sendable {
    let accountFingerprint: String
    let sourceScope: MirrorScope
    let targetScope: MirrorScope
    let sessionEpoch: Int

    func validate() throws {
        try sourceScope.validate()
        try targetScope.validate()
        guard !accountFingerprint.isEmpty,
              sourceScope.role == .owner,
              sourceScope.databaseScope == .private,
              sourceScope.zoneOwnerName == CKCurrentUserDefaultName,
              sourceScope.zoneName == HouseholdZoneRecoveryManifest.reservedSourceZoneName,
              targetScope.role == .owner,
              targetScope.databaseScope == .private,
              targetScope.zoneOwnerName == CKCurrentUserDefaultName,
              sourceScope.accountRecordName == targetScope.accountRecordName,
              (sourceScope.zoneOwnerName, sourceScope.zoneName)
                != (targetScope.zoneOwnerName, targetScope.zoneName) else {
            throw HouseholdZoneRecoveryViewModelError.invalidAuthority
        }
    }
}

struct HouseholdZoneRecoveryStoredArtifact: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let canonicalManifestBytes: Data
    let digest: String

    init(
        canonicalManifestBytes: Data,
        digest: String,
        formatVersion: Int = HouseholdZoneRecoveryStoredArtifact.currentFormatVersion
    ) throws {
        guard formatVersion == Self.currentFormatVersion,
              !canonicalManifestBytes.isEmpty,
              !digest.isEmpty else {
            throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
        }
        let manifest = try JSONDecoder().decode(
            HouseholdZoneRecoveryManifest.self,
            from: canonicalManifestBytes)
        guard try manifest.canonicalJSONBytes() == canonicalManifestBytes,
              try manifest.digest() == digest else {
            throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
        }
        self.formatVersion = formatVersion
        self.canonicalManifestBytes = canonicalManifestBytes
        self.digest = digest
    }

    func manifest() throws -> HouseholdZoneRecoveryManifest {
        let manifest = try JSONDecoder().decode(
            HouseholdZoneRecoveryManifest.self,
            from: canonicalManifestBytes)
        guard try manifest.canonicalJSONBytes() == canonicalManifestBytes,
              try manifest.digest() == digest else {
            throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
        }
        return manifest
    }
}

@MainActor
protocol HouseholdZoneRecoveryManifestStoring: AnyObject {
    func save(_ manifest: HouseholdZoneRecoveryManifest) throws -> HouseholdZoneRecoveryStoredArtifact
    func load() throws -> HouseholdZoneRecoveryStoredArtifact?
    func remove() throws
    func saveLastApplyOutcome(_ outcome: HouseholdZoneRecoveryApplyOutcome) throws
    func loadLastApplyOutcome() throws -> HouseholdZoneRecoveryApplyOutcome?
    /// Best-effort invalidation of the persisted outcome, called the moment a new run starts
    /// so a run killed mid-flight can never be reported using an older run's outcome.
    func removeLastApplyOutcome() throws
}

@MainActor
final class HouseholdZoneRecoveryManifestStore: HouseholdZoneRecoveryManifestStoring {
    let fileURL: URL

    convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
        self.init(directory: applicationSupport.appendingPathComponent(
            "HouseholdZoneRecovery",
            isDirectory: true))
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("approved-manifest.json", isDirectory: false)
    }

    private var outcomeFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("last-apply-outcome.json", isDirectory: false)
    }

    func save(_ manifest: HouseholdZoneRecoveryManifest) throws -> HouseholdZoneRecoveryStoredArtifact {
        let artifact = try HouseholdZoneRecoveryStoredArtifact(
            canonicalManifestBytes: manifest.canonicalJSONBytes(),
            digest: manifest.digest())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(try encoder.encode(artifact), to: fileURL)
        // A newly approved digest invalidates any outcome recorded against a prior manifest.
        try? DurableLifecycleFileSupport.remove(outcomeFileURL)
        return artifact
    }

    func load() throws -> HouseholdZoneRecoveryStoredArtifact? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoded = try JSONDecoder().decode(
            HouseholdZoneRecoveryStoredArtifact.self,
            from: Data(contentsOf: fileURL))
        return try HouseholdZoneRecoveryStoredArtifact(
            canonicalManifestBytes: decoded.canonicalManifestBytes,
            digest: decoded.digest,
            formatVersion: decoded.formatVersion)
    }

    func remove() throws {
        try DurableLifecycleFileSupport.remove(fileURL)
        try? DurableLifecycleFileSupport.remove(outcomeFileURL)
    }

    func saveLastApplyOutcome(_ outcome: HouseholdZoneRecoveryApplyOutcome) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(try encoder.encode(outcome), to: outcomeFileURL)
    }

    func loadLastApplyOutcome() throws -> HouseholdZoneRecoveryApplyOutcome? {
        guard FileManager.default.fileExists(atPath: outcomeFileURL.path) else { return nil }
        return try JSONDecoder().decode(
            HouseholdZoneRecoveryApplyOutcome.self,
            from: Data(contentsOf: outcomeFileURL))
    }

    func removeLastApplyOutcome() throws {
        try DurableLifecycleFileSupport.remove(outcomeFileURL)
    }
}

@MainActor
protocol HouseholdZoneRecoveryApplyBoundary:
    AnyObject,
    HouseholdZoneRecoveryApplySessionFence
{
    func unparkNormalSession() async
}

/// Read-only view of an AppState-owned apply run, observed by the view model without owning
/// the driving `Task` (see `AppState.activeHouseholdZoneRecoveryApplyRun`). The production
/// `HouseholdZoneRecoveryApplyRun` conforms retroactively below; tests substitute a fake so
/// the view model can be exercised without a real `AppState`.
@MainActor
protocol HouseholdZoneRecoveryApplyRunObserving: AnyObject {
    var state: HouseholdZoneRecoveryApplyRunState { get }
    var diagnostic: HouseholdZoneRecoveryApplyDiagnostic? { get }
    var localConflictIdentity: HouseholdZoneRecoveryIdentity? { get }
}

extension HouseholdZoneRecoveryApplyRun: HouseholdZoneRecoveryApplyRunObserving {}

@MainActor
protocol HouseholdZoneRecoveryApplying: AnyObject {
    var totalBatchCount: Int { get }
    func apply(maximumBatchCount: Int) async -> HouseholdZoneRecoveryApplyResult
}

nonisolated final class HouseholdZoneRecoveryProductionApplyOperation: HouseholdZoneRecoveryApplying {
    let totalBatchCount: Int
    private let applier: HouseholdZoneRecoveryApplier

    nonisolated private init(
        applier: HouseholdZoneRecoveryApplier,
        totalBatchCount: Int
    ) {
        self.applier = applier
        self.totalBatchCount = totalBatchCount
    }

    nonisolated static func prepare(
        artifact: HouseholdZoneRecoveryStoredArtifact,
        authority: HouseholdZoneRecoveryAuthoritySnapshot,
        boundary: any HouseholdZoneRecoveryApplyBoundary
    ) async throws -> HouseholdZoneRecoveryProductionApplyOperation {
        let manifest = try artifact.manifest()
        let approval = HouseholdZoneRecoveryApproval(manifestDigest: artifact.digest)
        try manifest.verify(approval)
        guard manifest.accountFingerprint == authority.accountFingerprint,
              manifest.sourceScope == authority.sourceScope,
              manifest.targetScope == authority.targetScope else {
            throw HouseholdZoneRecoveryViewModelError.invalidAuthority
        }

        let transport = CloudKitHouseholdZoneRecoveryTransport()
        let sourceZoneID = CKRecordZone.ID(
            zoneName: manifest.sourceScope.zoneName,
            ownerName: manifest.sourceScope.zoneOwnerName)
        let targetZoneID = CKRecordZone.ID(
            zoneName: manifest.targetScope.zoneName,
            ownerName: manifest.targetScope.zoneOwnerName)
        let sourceRecords = try await fetchAllRecords(
            in: sourceZoneID,
            transport: transport)
        let targetRecords = try await fetchAllRecords(
            in: targetZoneID,
            transport: transport)
        let plan = try HouseholdZoneRecoveryApplyPlan(
            manifest: manifest,
            approval: approval,
            sourceRecords: sourceRecords,
            targetRecords: targetRecords)
        let capturedAuthority = try await boundary.currentAuthoritySnapshot()
        guard capturedAuthority.accountFingerprint == authority.accountFingerprint,
              capturedAuthority.sourceScope == authority.sourceScope,
              capturedAuthority.targetScope == authority.targetScope,
              await boundary.normalSessionIsParked() else {
            throw HouseholdZoneRecoveryViewModelError.invalidAuthority
        }
        let applier = HouseholdZoneRecoveryApplier(
            manifest: manifest,
            approval: approval,
            applyPlan: plan,
            capturedAuthority: capturedAuthority,
            sessionFence: boundary,
            transport: transport)
        return HouseholdZoneRecoveryProductionApplyOperation(
            applier: applier,
            totalBatchCount: plan.batches.count)
    }

    nonisolated func apply(maximumBatchCount: Int) async -> HouseholdZoneRecoveryApplyResult {
        await applier.apply(maximumBatchCount: maximumBatchCount)
    }

    nonisolated private static func fetchAllRecords(
        in zoneID: CKRecordZone.ID,
        transport: any HouseholdZoneRecoveryTransport
    ) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: HouseholdZoneRecoveryPageCursor?
        var cursorIDs = Set<String>()
        var recordIDs = Set<CKRecord.ID>()
        repeat {
            let page = try await transport.fetchRecordPage(
                in: zoneID,
                after: cursor,
                desiredKeys: nil)
            guard page.zoneID == zoneID,
                  page.partialFailureCount == 0,
                  page.records.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
                throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
            }
            for record in page.records {
                guard recordIDs.insert(record.recordID).inserted else {
                    throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
                }
                records.append(record)
            }
            cursor = page.nextCursor
            if let cursor, !cursorIDs.insert(cursor.identifier).inserted {
                throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
            }
        } while cursor != nil
        return records
    }
}

enum HouseholdZoneRecoveryViewModelError: Error, Equatable, Sendable {
    case invalidAuthority
    case invalidAnalysisScope
    case invalidStoredArtifact
}

struct HouseholdZoneRecoveryReviewItem: Identifiable, Equatable, Sendable {
    enum Bucket: Equatable, Sendable {
        case candidate
        case unresolved
        case blocked
    }

    let id: HouseholdZoneRecoveryIdentity
    let bucket: Bucket
    let recordTypeLabel: String
    let recordLabel: String
    let dateLabel: String?
    let action: HouseholdZoneRecoveryAction?
    let conflictDecision: HouseholdZoneRecoveryDecision?
    let provenanceDecision: HouseholdZoneRecoveryProvenanceDecision?
    let blockedReason: String?
}

struct HouseholdZoneRecoveryPreview: Equatable, Sendable {
    let authority: HouseholdZoneRecoveryAuthoritySnapshot
    let manifest: HouseholdZoneRecoveryManifest
    let summary: HouseholdZoneRecoveryPreviewSummary
    let digest: String
    let canonicalManifestBytes: Data
    let approvalAvailable: Bool
}

/// Durable, privacy-safe snapshot of the last finished household-zone-recovery apply run.
/// Persisted beside the approved manifest so a torn-down, backgrounded, or previously killed
/// apply's outcome is still readable on the next view appearance. Contains only enum/count
/// fields — never record names, field values, digests, or other household content.
struct HouseholdZoneRecoveryApplyOutcome: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case resumableStop
        case conflict
        case verifiedCompletion
        case failed
    }

    let kind: Kind
    let completedBatchCount: Int
    let totalBatchCount: Int
    let diagnosticCategory: HouseholdZoneRecoveryApplyDiagnosticCategory?
    let diagnosticBatchIndex: Int?
    let diagnosticBatchRecordCount: Int?
}

@MainActor
@Observable
final class HouseholdZoneRecoveryViewModel {
    enum State: Equatable, Sendable {
        case idle
        case analyzing
        case preview(HouseholdZoneRecoveryPreview)
        case failed(String)
    }

    enum ApplyState: Equatable, Sendable {
        case idle
        case awaitingDestructiveConfirmation
        case preparing
        case applying(completedBatchCount: Int, totalBatchCount: Int)
        case resumableStop(completedBatchCount: Int, totalBatchCount: Int)
        case conflict(completedBatchCount: Int, totalBatchCount: Int)
        case verifiedCompletion(completedBatchCount: Int, totalBatchCount: Int)
        case failed(String)
    }

    typealias AuthoritySnapshotProvider = @MainActor () async throws -> HouseholdZoneRecoveryAuthoritySnapshot
    typealias AuthorityValidator = @MainActor (HouseholdZoneRecoveryAuthoritySnapshot) -> Bool
    typealias AnalysisProvider = @MainActor (
        HouseholdZoneRecoveryAuthoritySnapshot,
        [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryProvenanceDecision],
        [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryDecision]
    ) async throws -> HouseholdZoneRecoveryAnalysis
    /// Requests that `AppState` start (and own) the apply run; returns `nil` when `AppState`
    /// refuses to start one (build gate, digest/authority mismatch, or one already in flight).
    typealias ApplyRunStarter = @MainActor (
        HouseholdZoneRecoveryStoredArtifact,
        String,
        HouseholdZoneRecoveryAuthoritySnapshot
    ) -> (any HouseholdZoneRecoveryApplyRunObserving)?
    typealias ApplyRunCanceler = @MainActor () -> Void
    typealias ActiveApplyRunProvider = @MainActor () -> (any HouseholdZoneRecoveryApplyRunObserving)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.simmersmith.ios",
        category: "HouseholdZoneRecovery")

    private let isRecoveryAvailable: () -> Bool
    private let authoritySnapshot: AuthoritySnapshotProvider
    private let authorityIsCurrent: AuthorityValidator
    private let analysisProvider: AnalysisProvider
    private let manifestStore: any HouseholdZoneRecoveryManifestStoring
    private let startApplyRun: ApplyRunStarter?
    private let cancelApplyRun: ApplyRunCanceler?
    private let activeApplyRun: ActiveApplyRunProvider?
    private var approvedAuthority: HouseholdZoneRecoveryAuthoritySnapshot?
    private var analysisTask: Task<Void, Never>?
    private var requestGeneration = 0

    /// Apply state when no `AppState`-owned run is active: pre-run gating (idle/awaiting
    /// confirmation/local gate failures) or a terminal outcome restored from disk or from a
    /// run that has since finished. Superseded by the live run's state whenever one exists.
    private var localApplyState: ApplyState = .idle
    private var restoredDiagnostic: HouseholdZoneRecoveryApplyDiagnostic?
    /// `true` only when `localApplyState` came from `last-apply-outcome.json` (a genuinely
    /// previous session's result), never when it reflects a run this instance just observed
    /// finish live. Drives the "Previous attempt" framing so a restored outcome can never be
    /// mistaken for a fresh result.
    private var restoredFromDisk = false
    /// `true` from the moment the operator requests a fresh destructive confirmation until
    /// either that attempt actually starts a run or this instance re-enters the restore/
    /// analyze path. Explicitly recorded rather than inferred from `localApplyState`, because
    /// `.idle` is ALSO the value of a brand-new instance's initial state and of a restore that
    /// found no outcome file — exactly the state of any instance mounted while a run already
    /// in flight (started by another instance) has not yet finished. Inferring "fresh attempt"
    /// from `.idle` would make such an instance collapse that run's terminal outcome to idle
    /// the moment it finishes, hiding a real failure as "nothing happened".
    private var freshAttemptRequested = false

    private(set) var state: State = .idle
    private(set) var storedApprovalDigest: String?
    var typedDigestConfirmation = ""

    init(
        isRecoveryAvailable: @escaping () -> Bool,
        authoritySnapshot: @escaping AuthoritySnapshotProvider,
        authorityIsCurrent: @escaping AuthorityValidator,
        analyze: @escaping AnalysisProvider,
        manifestStore: any HouseholdZoneRecoveryManifestStoring,
        startApplyRun: ApplyRunStarter? = nil,
        cancelApplyRun: ApplyRunCanceler? = nil,
        activeApplyRun: ActiveApplyRunProvider? = nil
    ) {
        self.isRecoveryAvailable = isRecoveryAvailable
        self.authoritySnapshot = authoritySnapshot
        self.authorityIsCurrent = authorityIsCurrent
        analysisProvider = analyze
        self.manifestStore = manifestStore
        self.startApplyRun = startApplyRun
        self.cancelApplyRun = cancelApplyRun
        self.activeApplyRun = activeApplyRun
    }

    convenience init(appState: AppState) {
        self.init(
            isRecoveryAvailable: { DebugGate.showsCloudKitChecks },
            authoritySnapshot: { try await appState.householdZoneRecoveryAuthoritySnapshot() },
            authorityIsCurrent: { appState.isCurrentHouseholdZoneRecoveryAuthority($0) },
            analyze: { authority, provenanceDecisions, conflictDecisions in
                try await HouseholdZoneRecoveryAnalyzer(
                    transport: CloudKitHouseholdZoneRecoveryTransport()).analyze(
                        accountFingerprint: authority.accountFingerprint,
                        sourceScope: authority.sourceScope,
                        targetScope: authority.targetScope,
                        provenanceDecisions: provenanceDecisions,
                        conflictDecisions: conflictDecisions)
            },
            manifestStore: HouseholdZoneRecoveryManifestStore(),
            startApplyRun: { artifact, confirmedDigest, authority in
                appState.startHouseholdZoneRecoveryApply(
                    artifact: artifact,
                    confirmedDigest: confirmedDigest,
                    authority: authority)
            },
            cancelApplyRun: { appState.cancelHouseholdZoneRecoveryApply() },
            activeApplyRun: { appState.activeHouseholdZoneRecoveryApplyRun })
    }

    var preview: HouseholdZoneRecoveryPreview? {
        guard case .preview(let preview) = state else { return nil }
        return preview
    }

    var failureMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    var manifestDigest: String? { preview?.digest }
    var canonicalManifestBytes: Data? { preview?.canonicalManifestBytes }
    var approvalAvailable: Bool { preview?.approvalAvailable == true }
    var diagnosticDescription: String { preview?.summary.diagnosticDescription ?? "state=unavailable" }
    var undecidedProvenanceCount: Int {
        preview?.manifest.unresolvedEntries.lazy.filter { $0.decision == nil }.count ?? 0
    }

    var canRequestApplyConfirmation: Bool {
        guard let storedApprovalDigest, let approvedAuthority else { return false }
        return isRecoveryAvailable()
            && typedDigestConfirmation == storedApprovalDigest
            && authorityIsCurrent(approvedAuthority)
            && !applyIsRunning
    }

    /// True whenever `AppState` owns a run that has not yet reached a terminal state. Used
    /// only to gate a *fresh start* (`confirmApply`) against a concurrent in-flight run — a
    /// terminal run must never block starting a new one.
    private var hasNonTerminalActiveRun: Bool {
        guard let run = activeApplyRun?() else { return false }
        return !Self.isTerminal(run.state)
    }

    /// True when the run `AppState` currently owns should still dictate the screen: either
    /// it hasn't finished yet, or it has finished but the operator has not yet explicitly
    /// requested a fresh attempt. A run that just finished still owns the screen until a
    /// fresh attempt begins — only then does it stop being authoritative, even though
    /// `AppState` keeps retaining it. This is what lets a live run's own conflict identity
    /// render while it's the current result, yet keeps a stale identity or an un-prefixed
    /// restored outcome from sitting beside a NEW attempt. Deliberately keyed off the
    /// explicit `freshAttemptRequested` flag rather than `localApplyState == .idle`: `.idle`
    /// is also the initial state of a brand-new instance and of a restore that found no
    /// outcome file, so a view model mounted while another instance's run is still in
    /// flight must keep rendering that run's terminal outcome instead of collapsing to idle.
    private var runIsAuthoritative: Bool {
        guard let run = activeApplyRun?() else { return false }
        guard Self.isTerminal(run.state) else { return true }
        return !freshAttemptRequested
    }

    /// Live when `AppState` owns a run that has not finished, or when this instance is
    /// between requesting and receiving that run. Once a run reaches a terminal state it
    /// stops dictating the screen the moment a fresh local attempt begins: a pre-run local
    /// state (idle / awaiting confirmation) wins so re-confirming and starting a fresh run
    /// is always possible without relaunching.
    var applyState: ApplyState {
        guard let run = activeApplyRun?() else { return localApplyState }
        return runIsAuthoritative ? Self.mapRunState(run.state) : localApplyState
    }

    var applyDiagnostic: HouseholdZoneRecoveryApplyDiagnostic? {
        if let run = activeApplyRun?() {
            return run.diagnostic
        }
        return restoredDiagnostic
    }

    var localConflictIdentity: HouseholdZoneRecoveryIdentity? {
        guard runIsAuthoritative else { return nil }
        return activeApplyRun?()?.localConflictIdentity
    }

    var applyIsRunning: Bool {
        switch applyState {
        case .preparing, .applying:
            return true
        default:
            return false
        }
    }

    var storedApprovalAuthority: HouseholdZoneRecoveryAuthoritySnapshot? {
        approvedAuthority
    }

    var applyFailureMessage: String? {
        guard case .failed(let message) = applyState else { return nil }
        return message
    }

    var applyStatusMessage: String {
        let isRestored = !runIsAuthoritative && restoredFromDisk
        switch applyState {
        case .idle:
            return storedApprovalDigest == nil
                ? "No verified approved manifest is stored on this device."
                : "Enter the exact approved digest to continue."
        case .awaitingDestructiveConfirmation:
            return "Review the final confirmation."
        case .preparing:
            return "Parking normal sync and verifying the approved manifest…"
        case .applying(let completed, let total):
            return "Applied \(completed) of \(total) bounded batches."
        case .resumableStop(let completed, let total):
            let base = "Recovery stopped safely after \(completed) of \(total) batches"
                + "\(Self.diagnosticClause(applyDiagnostic)). Resume manually with the same digest."
            return isRestored ? "Previous attempt — " + base : base
        case .conflict:
            let base = "Recovery stopped because target data changed\(Self.diagnosticClause(applyDiagnostic))."
            return isRestored ? "Previous attempt — " + base : base
        case .verifiedCompletion(let completed, let total):
            let base = "Verified recovery completion: \(completed) of \(total) batches."
            return isRestored ? "Previous attempt — " + base : base
        case .failed(let message):
            return isRestored ? "Previous attempt — \(message)" : message
        }
    }

    var destructiveConfirmationMessage: String {
        "This copies only the approved records into the active household. "
            + "The reserved source zone is preserved and is never deleted or changed. "
            + "Recovery stops safely on any authority change, conflict, or error."
    }

    func loadStoredApproval() async {
        guard isRecoveryAvailable() else {
            storedApprovalDigest = nil
            approvedAuthority = nil
            localApplyState = .failed("Recovery apply is unavailable in this build.")
            restoredDiagnostic = nil
            restoredFromDisk = false
            return
        }
        do {
            guard let artifact = try manifestStore.load() else {
                storedApprovalDigest = nil
                approvedAuthority = nil
                restoreLastOutcomeIfAvailable()
                return
            }
            let manifest = try artifact.manifest()
            let authority = try await authoritySnapshot()
            try authority.validate()
            guard manifest.accountFingerprint == authority.accountFingerprint,
                  manifest.sourceScope == authority.sourceScope,
                  manifest.targetScope == authority.targetScope,
                  authorityIsCurrent(authority) else {
                throw HouseholdZoneRecoveryViewModelError.invalidAuthority
            }
            storedApprovalDigest = artifact.digest
            approvedAuthority = authority
            restoreLastOutcomeIfAvailable()
        } catch {
            storedApprovalDigest = nil
            approvedAuthority = nil
            localApplyState = .failed("The stored recovery approval could not be verified.")
            restoredDiagnostic = nil
            restoredFromDisk = false
            Self.logger.error("apply_approval_load_failed")
        }
    }

    func requestApplyConfirmation() {
        guard canRequestApplyConfirmation else { return }
        localApplyState = .awaitingDestructiveConfirmation
        restoredFromDisk = false
        freshAttemptRequested = true
    }

    func cancelApplyConfirmation() {
        guard localApplyState == .awaitingDestructiveConfirmation else { return }
        localApplyState = .idle
    }

    /// Re-validates the destructive gate at confirm time (authority/digest can go stale
    /// between the first and second confirmation), then asks `AppState` to start (and own)
    /// the run. This view model never builds or holds the driving `Task` itself, so tearing
    /// down the view can never cancel an in-flight apply.
    func confirmApply() {
        guard localApplyState == .awaitingDestructiveConfirmation,
              !hasNonTerminalActiveRun else { return }
        guard isRecoveryAvailable() else {
            localApplyState = .failed("Recovery apply is unavailable in this build.")
            restoredFromDisk = false
            return
        }
        guard let confirmedDigest = storedApprovalDigest,
              typedDigestConfirmation == confirmedDigest,
              let approvedAuthority,
              authorityIsCurrent(approvedAuthority) else {
            localApplyState = .failed("The household session changed before recovery apply.")
            restoredFromDisk = false
            return
        }
        guard let artifact = try? manifestStore.load(), artifact.digest == confirmedDigest else {
            localApplyState = .failed("The approved recovery manifest changed. Review it again.")
            restoredFromDisk = false
            return
        }
        guard let startApplyRun,
              let run = startApplyRun(artifact, confirmedDigest, approvedAuthority) else {
            localApplyState = .failed("Recovery apply could not start. Review it again.")
            restoredFromDisk = false
            return
        }
        // The prior run's outcome must never be attributed to this fresh attempt: a run
        // killed mid-flight would otherwise resurrect and understate what came before it.
        try? manifestStore.removeLastApplyOutcome()
        restoredFromDisk = false
        restoredDiagnostic = nil
        freshAttemptRequested = false
        localApplyState = .preparing
        beginTrackingCompletion(of: run)
    }

    /// The only path that may stop an `AppState`-owned run. Never wired to view teardown.
    func cancelApply() {
        cancelApplyRun?()
    }


    var reviewItems: [HouseholdZoneRecoveryReviewItem] {
        guard let manifest = preview?.manifest else { return [] }
        let candidates = manifest.entries.map {
            Self.reviewItem(entry: $0, bucket: .candidate, provenanceDecision: nil)
        }
        let unresolved = manifest.unresolvedEntries.map {
            Self.reviewItem(
                entry: $0.entry,
                bucket: .unresolved,
                provenanceDecision: $0.decision)
        }
        return (candidates + unresolved).sorted { $0.id.source.sortKey < $1.id.source.sortKey }
    }

    var blockedItems: [HouseholdZoneRecoveryReviewItem] {
        guard let manifest = preview?.manifest else { return [] }
        return manifest.blockedEntries.map {
            let labels = Self.labels(for: $0.identity)
            return HouseholdZoneRecoveryReviewItem(
                id: $0.identity,
                bucket: .blocked,
                recordTypeLabel: labels.recordType,
                recordLabel: labels.record,
                dateLabel: labels.date,
                action: nil,
                conflictDecision: nil,
                provenanceDecision: nil,
                blockedReason: Self.blockedReasonLabel($0.reason))
        }.sorted { $0.id.source.sortKey < $1.id.source.sortKey }
    }

    func analyze() {
        guard !applyIsRunning else { return }
        guard isRecoveryAvailable() else {
            state = .failed("Recovery analysis is unavailable in this build.")
            return
        }
        storedApprovalDigest = nil
        approvedAuthority = nil
        typedDigestConfirmation = ""
        localApplyState = .idle
        restoredDiagnostic = nil
        restoredFromDisk = false
        freshAttemptRequested = false
        analysisTask?.cancel()
        requestGeneration &+= 1
        let generation = requestGeneration
        state = .analyzing
        analysisTask = Task { [weak self] in
            await self?.performAnalysis(generation: generation)
        }
    }

    func cancelAnalysis() {
        requestGeneration &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        state = .idle
        Self.logger.info("analysis_cancelled")
    }

    func decideConflict(
        _ identity: HouseholdZoneRecoveryIdentity,
        decision: HouseholdZoneRecoveryDecision
    ) {
        guard !applyIsRunning else { return }
        guard let preview else { return }
        guard authorityIsCurrent(preview.authority) else {
            authorityChangedDuringReview()
            return
        }
        do {
            let entries = preview.manifest.entries.map { entry in
                guard entry.identity == identity, entry.action == .conflict else { return entry }
                return Self.entry(entry, conflictDecision: decision)
            }
            let unresolved = preview.manifest.unresolvedEntries.map { unresolved in
                guard unresolved.identity == identity,
                      unresolved.entry.action == .conflict else { return unresolved }
                return HouseholdZoneRecoveryUnresolvedEntry(
                    entry: Self.entry(unresolved.entry, conflictDecision: decision),
                    decision: unresolved.decision)
            }
            try publishRebuiltManifest(
                from: preview,
                entries: entries,
                unresolved: unresolved)
            Self.logger.info("conflict_decision_changed")
        } catch {
            failStorageOrDecision()
        }
    }

    func decideAllProvenance(_ decision: HouseholdZoneRecoveryProvenanceDecision) {
        guard !applyIsRunning else { return }
        guard let preview else { return }
        let undecidedCount = preview.manifest.unresolvedEntries.lazy
            .filter { $0.decision == nil }
            .count
        guard undecidedCount > 0 else { return }
        guard authorityIsCurrent(preview.authority) else {
            authorityChangedDuringReview()
            return
        }
        do {
            let unresolved = preview.manifest.unresolvedEntries.map { unresolved in
                guard unresolved.decision == nil else { return unresolved }
                return HouseholdZoneRecoveryUnresolvedEntry(
                    entry: unresolved.entry,
                    decision: decision)
            }
            try publishRebuiltManifest(
                from: preview,
                entries: preview.manifest.entries,
                unresolved: unresolved)
            Self.logger.info(
                "provenance_bulk_decision_changed count=\(undecidedCount, privacy: .public)")
        } catch {
            failStorageOrDecision()
        }
    }

    func decideProvenance(
        _ identity: HouseholdZoneRecoveryIdentity,
        decision: HouseholdZoneRecoveryProvenanceDecision
    ) {
        guard !applyIsRunning else { return }
        guard let preview else { return }
        guard authorityIsCurrent(preview.authority) else {
            authorityChangedDuringReview()
            return
        }
        do {
            let unresolved = preview.manifest.unresolvedEntries.map { unresolved in
                guard unresolved.identity == identity else { return unresolved }
                return HouseholdZoneRecoveryUnresolvedEntry(
                    entry: unresolved.entry,
                    decision: decision)
            }
            try publishRebuiltManifest(
                from: preview,
                entries: preview.manifest.entries,
                unresolved: unresolved)
            Self.logger.info("provenance_decision_changed")
        } catch {
            failStorageOrDecision()
        }
    }

    /// Observes the AppState-owned run without polling (via `withObservationTracking`) and
    /// persists its outcome exactly once it reaches a terminal state. Deliberately captures
    /// `self` strongly and is never cancelled by view teardown: it must keep this view model
    /// alive long enough to write `last-apply-outcome.json` even after the SwiftUI view (and
    /// its `@State`-held reference to this instance) has been torn down. It exits on its own
    /// as soon as the terminal outcome is persisted.
    private func beginTrackingCompletion(of run: any HouseholdZoneRecoveryApplyRunObserving) {
        Task {
            await Self.awaitTerminalState(of: run)
            persistOutcome(from: run)
        }
    }

    private static func awaitTerminalState(of run: any HouseholdZoneRecoveryApplyRunObserving) async {
        while !isTerminal(run.state) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = run.state
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    private static func isTerminal(_ state: HouseholdZoneRecoveryApplyRunState) -> Bool {
        switch state {
        case .preparing, .applying:
            return false
        case .resumableStop, .conflict, .verifiedCompletion, .failed:
            return true
        }
    }

    private func persistOutcome(from run: any HouseholdZoneRecoveryApplyRunObserving) {
        guard let outcome = Self.outcome(from: run.state, diagnostic: run.diagnostic) else { return }
        localApplyState = Self.applyState(from: outcome)
        restoredDiagnostic = Self.diagnostic(from: outcome)
        restoredFromDisk = false
        do {
            try manifestStore.saveLastApplyOutcome(outcome)
            Self.logger.info(
                "apply_outcome_persisted kind=\(outcome.kind.rawValue, privacy: .public) completed=\(outcome.completedBatchCount, privacy: .public) total=\(outcome.totalBatchCount, privacy: .public) diagnosticCategory=\(outcome.diagnosticCategory?.rawValue ?? "none", privacy: .public)")
        } catch {
            Self.logger.error(
                "apply_outcome_persist_failed kind=\(outcome.kind.rawValue, privacy: .public) completed=\(outcome.completedBatchCount, privacy: .public) total=\(outcome.totalBatchCount, privacy: .public)")
        }
    }

    private func restoreLastOutcomeIfAvailable() {
        freshAttemptRequested = false
        guard let outcome = try? manifestStore.loadLastApplyOutcome() else {
            localApplyState = .idle
            restoredDiagnostic = nil
            restoredFromDisk = false
            return
        }
        localApplyState = Self.applyState(from: outcome)
        restoredDiagnostic = Self.diagnostic(from: outcome)
        restoredFromDisk = true
    }

    private func publish(
        analysis: HouseholdZoneRecoveryAnalysis,
        authority: HouseholdZoneRecoveryAuthoritySnapshot
    ) throws {
        let preview = try Self.makePreview(
            authority: authority,
            manifest: analysis.manifest,
            summary: analysis.summary)
        try persistIfApprovable(preview)
        state = .preview(preview)
    }

    private func performAnalysis(generation: Int) async {
        do {
            try manifestStore.remove()
            let authority = try await authoritySnapshot()
            try Task.checkCancellation()
            try authority.validate()
            let analysis = try await analysisProvider(authority, [:], [:])
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            guard authorityIsCurrent(authority) else {
                state = .failed("The household session changed during recovery analysis.")
                return
            }
            guard analysis.manifest.accountFingerprint == authority.accountFingerprint,
                  analysis.manifest.sourceScope == authority.sourceScope,
                  analysis.manifest.targetScope == authority.targetScope else {
                throw HouseholdZoneRecoveryViewModelError.invalidAnalysisScope
            }
            try publish(analysis: analysis, authority: authority)
            Self.logger.info(
                "analysis_complete \(analysis.summary.diagnosticDescription, privacy: .public)")
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state = .idle
        } catch HouseholdZoneRecoveryViewModelError.invalidAuthority {
            guard generation == requestGeneration else { return }
            state = .failed("Recovery analysis could not verify the active owner household.")
            Self.logger.error("analysis_authority_rejected")
        } catch {
            guard generation == requestGeneration else { return }
            state = .failed("Recovery analysis failed without changing household data.")
            Self.logger.error("analysis_failed")
        }
        if generation == requestGeneration {
            analysisTask = nil
        }
    }

    private func publishRebuiltManifest(
        from prior: HouseholdZoneRecoveryPreview,
        entries: [HouseholdZoneRecoveryEntry],
        unresolved: [HouseholdZoneRecoveryUnresolvedEntry]
    ) throws {
        let manifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: prior.manifest.accountFingerprint,
            sourceScope: prior.manifest.sourceScope,
            targetScope: prior.manifest.targetScope,
            sourceInputFingerprint: prior.manifest.sourceInputFingerprint,
            targetInputFingerprint: prior.manifest.targetInputFingerprint,
            entries: entries,
            exclusions: prior.manifest.exclusions,
            unresolvedEntries: unresolved,
            blockedEntries: prior.manifest.blockedEntries,
            formatVersion: prior.manifest.formatVersion)
        let summary = HouseholdZoneRecoveryPreviewSummary(
            candidateCount: prior.summary.candidateCount,
            copyCount: prior.summary.copyCount,
            skipIdenticalCount: prior.summary.skipIdenticalCount,
            conflictCount: prior.summary.conflictCount,
            excludedCount: prior.summary.excludedCount,
            unresolvedCount: manifest.unresolvedEntries.filter { $0.decision == nil }.count,
            blockedCount: manifest.blockedEntries.count,
            assetCount: prior.summary.assetCount)
        let rebuilt = try Self.makePreview(
            authority: prior.authority,
            manifest: manifest,
            summary: summary)
        try persistIfApprovable(rebuilt)
        state = .preview(rebuilt)
    }

    private func persistIfApprovable(_ preview: HouseholdZoneRecoveryPreview) throws {
        guard preview.approvalAvailable else {
            try manifestStore.remove()
            storedApprovalDigest = nil
            approvedAuthority = nil
            return
        }
        let artifact = try manifestStore.save(preview.manifest)
        storedApprovalDigest = artifact.digest
        approvedAuthority = preview.authority
        localApplyState = .idle
        restoredDiagnostic = nil
        restoredFromDisk = false
    }

    private func authorityChangedDuringReview() {
        try? manifestStore.remove()
        storedApprovalDigest = nil
        approvedAuthority = nil
        state = .failed("The household session changed during recovery review.")
        Self.logger.error("review_authority_changed")
    }

    private func failStorageOrDecision() {
        try? manifestStore.remove()
        storedApprovalDigest = nil
        approvedAuthority = nil
        state = .failed("Recovery choices could not be stored safely. Analyze again.")
        Self.logger.error("decision_store_failed")
    }

    private static func makePreview(
        authority: HouseholdZoneRecoveryAuthoritySnapshot,
        manifest: HouseholdZoneRecoveryManifest,
        summary: HouseholdZoneRecoveryPreviewSummary
    ) throws -> HouseholdZoneRecoveryPreview {
        let digest = try manifest.digest()
        let bytes = try manifest.canonicalJSONBytes()
        let approvalAvailable: Bool
        do {
            try manifest.verify(HouseholdZoneRecoveryApproval(manifestDigest: digest))
            approvalAvailable = true
        } catch {
            approvalAvailable = false
        }
        return HouseholdZoneRecoveryPreview(
            authority: authority,
            manifest: manifest,
            summary: summary,
            digest: digest,
            canonicalManifestBytes: bytes,
            approvalAvailable: approvalAvailable)
    }

    private static func entry(
        _ entry: HouseholdZoneRecoveryEntry,
        conflictDecision: HouseholdZoneRecoveryDecision
    ) -> HouseholdZoneRecoveryEntry {
        HouseholdZoneRecoveryEntry(
            identity: entry.identity,
            action: entry.action,
            decision: conflictDecision,
            dependencies: entry.dependencies,
            assetDigests: entry.assetDigests)
    }

    private static func reviewItem(
        entry: HouseholdZoneRecoveryEntry,
        bucket: HouseholdZoneRecoveryReviewItem.Bucket,
        provenanceDecision: HouseholdZoneRecoveryProvenanceDecision?
    ) -> HouseholdZoneRecoveryReviewItem {
        let labels = labels(for: entry.identity)
        return HouseholdZoneRecoveryReviewItem(
            id: entry.identity,
            bucket: bucket,
            recordTypeLabel: labels.recordType,
            recordLabel: labels.record,
            dateLabel: labels.date,
            action: entry.action,
            conflictDecision: entry.decision,
            provenanceDecision: provenanceDecision,
            blockedReason: nil)
    }

    private static func labels(
        for identity: HouseholdZoneRecoveryIdentity
    ) -> (recordType: String, record: String, date: String?) {
        let type = identity.source.recordType
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression)
        let recordName = identity.source.recordName
        let date: String?
        if let range = recordName.range(
            of: #"\d{4}-\d{2}-\d{2}"#,
            options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.date(from: String(recordName[range]))?.formatted(
                date: .abbreviated,
                time: .omitted)
        } else {
            date = nil
        }
        return (type, "\(type): \(recordName)", date)
    }

    private static func blockedReasonLabel(_ reason: String) -> String {
        reason == HouseholdZoneRecoveryBlockedEntry.missingDependencyReason
            ? "Missing required data"
            : "Not eligible for recovery"
    }

    private static func diagnosticClause(_ diagnostic: HouseholdZoneRecoveryApplyDiagnostic?) -> String {
        guard let diagnostic else { return "" }
        if let batchIndex = diagnostic.batchIndex, let batchRecordCount = diagnostic.batchRecordCount {
            return " (\(diagnostic.category.rawValue), batch \(batchIndex), \(batchRecordCount) records)"
        }
        return " (\(diagnostic.category.rawValue))"
    }

    private static func mapRunState(_ state: HouseholdZoneRecoveryApplyRunState) -> ApplyState {
        switch state {
        case .preparing:
            return .preparing
        case .applying(let completed, let total):
            return .applying(completedBatchCount: completed, totalBatchCount: total)
        case .resumableStop(let completed, let total):
            return .resumableStop(completedBatchCount: completed, totalBatchCount: total)
        case .conflict(let completed, let total):
            return .conflict(completedBatchCount: completed, totalBatchCount: total)
        case .verifiedCompletion(let completed, let total):
            return .verifiedCompletion(completedBatchCount: completed, totalBatchCount: total)
        case .failed(let message, _, _):
            return .failed(message)
        }
    }

    private static func outcome(
        from state: HouseholdZoneRecoveryApplyRunState,
        diagnostic: HouseholdZoneRecoveryApplyDiagnostic?
    ) -> HouseholdZoneRecoveryApplyOutcome? {
        switch state {
        case .preparing, .applying:
            return nil
        case .resumableStop(let completed, let total):
            return HouseholdZoneRecoveryApplyOutcome(
                kind: .resumableStop,
                completedBatchCount: completed,
                totalBatchCount: total,
                diagnosticCategory: diagnostic?.category,
                diagnosticBatchIndex: diagnostic?.batchIndex,
                diagnosticBatchRecordCount: diagnostic?.batchRecordCount)
        case .conflict(let completed, let total):
            return HouseholdZoneRecoveryApplyOutcome(
                kind: .conflict,
                completedBatchCount: completed,
                totalBatchCount: total,
                diagnosticCategory: diagnostic?.category,
                diagnosticBatchIndex: diagnostic?.batchIndex,
                diagnosticBatchRecordCount: diagnostic?.batchRecordCount)
        case .verifiedCompletion(let completed, let total):
            return HouseholdZoneRecoveryApplyOutcome(
                kind: .verifiedCompletion,
                completedBatchCount: completed,
                totalBatchCount: total,
                diagnosticCategory: nil,
                diagnosticBatchIndex: nil,
                diagnosticBatchRecordCount: nil)
        case .failed(_, let completed, let total):
            return HouseholdZoneRecoveryApplyOutcome(
                kind: .failed,
                completedBatchCount: completed,
                totalBatchCount: total,
                diagnosticCategory: diagnostic?.category,
                diagnosticBatchIndex: diagnostic?.batchIndex,
                diagnosticBatchRecordCount: diagnostic?.batchRecordCount)
        }
    }

    private static func applyState(from outcome: HouseholdZoneRecoveryApplyOutcome) -> ApplyState {
        switch outcome.kind {
        case .resumableStop:
            return .resumableStop(
                completedBatchCount: outcome.completedBatchCount,
                totalBatchCount: outcome.totalBatchCount)
        case .conflict:
            return .conflict(
                completedBatchCount: outcome.completedBatchCount,
                totalBatchCount: outcome.totalBatchCount)
        case .verifiedCompletion:
            return .verifiedCompletion(
                completedBatchCount: outcome.completedBatchCount,
                totalBatchCount: outcome.totalBatchCount)
        case .failed:
            let clause = diagnosticClause(diagnostic(from: outcome))
            return .failed(
                "Recovery apply stopped before completion after "
                    + "\(outcome.completedBatchCount) of \(outcome.totalBatchCount) batches\(clause).")
        }
    }

    private static func diagnostic(
        from outcome: HouseholdZoneRecoveryApplyOutcome
    ) -> HouseholdZoneRecoveryApplyDiagnostic? {
        guard let category = outcome.diagnosticCategory else { return nil }
        return HouseholdZoneRecoveryApplyDiagnostic(
            category: category,
            batchIndex: outcome.diagnosticBatchIndex,
            batchRecordCount: outcome.diagnosticBatchRecordCount)
    }
}

struct HouseholdZoneRecoveryView: View {
    @State private var viewModel: HouseholdZoneRecoveryViewModel

    init(appState: AppState) {
        _viewModel = State(initialValue: HouseholdZoneRecoveryViewModel(appState: appState))
    }

    var body: some View {
        Form {
            statusSection
            applySection
            if let preview = viewModel.preview {
                countSection(preview)
                reviewSection
                exclusionSection(preview)
                blockedSection
                manifestSection(preview)
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Household data recovery")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadStoredApproval() }
        .onDisappear {
            viewModel.cancelAnalysis()
        }
        .confirmationDialog(
            "Apply approved recovery manifest?",
            isPresented: Binding(
                get: { viewModel.applyState == .awaitingDestructiveConfirmation },
                set: { if !$0 { viewModel.cancelApplyConfirmation() } }),
            titleVisibility: .visible
        ) {
            Button(
                "Apply and preserve source",
                role: .destructive,
                action: viewModel.confirmApply)
            Button("Cancel", role: .cancel, action: viewModel.cancelApplyConfirmation)
        } message: {
            Text(viewModel.destructiveConfirmationMessage)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch viewModel.state {
            case .idle:
                Button("Analyze", systemImage: "magnifyingglass", action: viewModel.analyze)
            case .analyzing:
                HStack {
                    ProgressView()
                    Text("Analyzing exact household zones…")
                }
                Button("Cancel", role: .cancel, action: viewModel.cancelAnalysis)
            case .preview:
                Button("Analyze again", systemImage: "arrow.clockwise", action: viewModel.analyze)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try analysis again", systemImage: "arrow.clockwise", action: viewModel.analyze)
            }
        } header: {
            SmithSectionHeader("read-only analysis")
        } footer: {
            Text("Analyze reads only the reserved recovery zone and the exact active owner household. It never changes CloudKit data.")
        }
        .disabled(viewModel.applyIsRunning)
    }

    private var applySection: some View {
        Section {
            if let digest = viewModel.storedApprovalDigest {
                LabeledContent("Approved digest") {
                    Text(digest)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            TextField(
                "Enter exact approved digest",
                text: Binding(
                    get: { viewModel.typedDigestConfirmation },
                    set: { viewModel.typedDigestConfirmation = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.caption, design: .monospaced))
                .disabled(viewModel.applyIsRunning)

            switch viewModel.applyState {
            case .preparing:
                HStack {
                    ProgressView()
                    Text(viewModel.applyStatusMessage)
                }
                Button("Stop safely", role: .cancel, action: viewModel.cancelApply)
            case .applying(let completed, let total):
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1)))
                Text(viewModel.applyStatusMessage)
                    .foregroundStyle(.secondary)
                Button("Stop safely", role: .cancel, action: viewModel.cancelApply)
            case .resumableStop, .conflict, .verifiedCompletion, .failed:
                Text(viewModel.applyStatusMessage)
                    .foregroundStyle(.secondary)
            case .idle, .awaitingDestructiveConfirmation:
                EmptyView()
            }

            Button(
                "Review apply",
                systemImage: "checkmark.shield",
                action: viewModel.requestApplyConfirmation)
                .disabled(!viewModel.canRequestApplyConfirmation)
        } header: {
            SmithSectionHeader("approved apply")
        } footer: {
            Text("Applying is explicit and bounded. The reserved source zone is preserved and is never deleted or changed. A stopped recovery resumes only when you confirm the same digest again.")
        }
    }

    private func countSection(_ preview: HouseholdZoneRecoveryPreview) -> some View {
        Section {
            countRow("Candidates", preview.summary.candidateCount)
            countRow("Copy", preview.summary.copyCount)
            countRow("Identical", preview.summary.skipIdenticalCount)
            countRow("Conflicts", preview.summary.conflictCount)
            countRow("Excluded", preview.summary.excludedCount)
            countRow("Undecided provenance", preview.summary.unresolvedCount)
            countRow("Blocked", preview.summary.blockedCount)
        } header: {
            SmithSectionHeader("grouped counts")
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if !viewModel.reviewItems.isEmpty {
            Section {
                if viewModel.undecidedProvenanceCount > 0 {
                    Button {
                        viewModel.decideAllProvenance(.include)
                    } label: {
                        Label(
                            "Include all \(viewModel.undecidedProvenanceCount) undecided records",
                            systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                ForEach(viewModel.reviewItems) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.recordLabel)
                        HStack {
                            if let action = item.action {
                                Text(action.rawValue)
                            }
                            if let date = item.dateLabel {
                                Text(date)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if item.action == .conflict {
                            conflictDecisions(item)
                        }
                        if item.bucket == .unresolved {
                            provenanceDecisions(item)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                SmithSectionHeader("records to review")
            }
            .disabled(viewModel.applyIsRunning)
        }
    }

    @ViewBuilder
    private func exclusionSection(_ preview: HouseholdZoneRecoveryPreview) -> some View {
        if !preview.manifest.exclusions.isEmpty {
            Section {
                ForEach(preview.manifest.exclusions, id: \.reason) { exclusion in
                    countRow(Self.exclusionLabel(exclusion.reason), exclusion.count)
                }
            } header: {
                SmithSectionHeader("excluded")
            }
        }
    }

    @ViewBuilder
    private var blockedSection: some View {
        if !viewModel.blockedItems.isEmpty {
            Section {
                ForEach(viewModel.blockedItems) { item in
                    VStack(alignment: .leading) {
                        Text(item.recordLabel)
                        Text(item.blockedReason ?? "Not eligible for recovery")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SmithSectionHeader("blocked")
            }
        }
    }

    private func manifestSection(_ preview: HouseholdZoneRecoveryPreview) -> some View {
        Section {
            LabeledContent("Digest") {
                Text(preview.digest)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Local artifact") {
                Text(preview.approvalAvailable ? "Ready" : "Waiting for decisions")
            }
        } header: {
            SmithSectionHeader("canonical manifest")
        } footer: {
            Text("The complete manifest stays in Application Support only after every required decision is made. Apply accepts only this exact stored digest.")
        }
    }

    private func conflictDecisions(_ item: HouseholdZoneRecoveryReviewItem) -> some View {
        HStack {
            Button {
                viewModel.decideConflict(item.id, decision: .source)
            } label: {
                Label("Use source", systemImage: item.conflictDecision == .source ? "checkmark.circle.fill" : "circle")
            }
            Button {
                viewModel.decideConflict(item.id, decision: .target)
            } label: {
                Label("Keep target", systemImage: item.conflictDecision == .target ? "checkmark.circle.fill" : "circle")
            }
        }
        .buttonStyle(.bordered)
    }

    private func provenanceDecisions(_ item: HouseholdZoneRecoveryReviewItem) -> some View {
        HStack {
            Button {
                viewModel.decideProvenance(item.id, decision: .include)
            } label: {
                Label("Include", systemImage: item.provenanceDecision == .include ? "checkmark.circle.fill" : "circle")
            }
            Button {
                viewModel.decideProvenance(item.id, decision: .exclude)
            } label: {
                Label("Exclude", systemImage: item.provenanceDecision == .exclude ? "checkmark.circle.fill" : "circle")
            }
        }
        .buttonStyle(.bordered)
    }

    private func countRow(_ label: String, _ count: Int) -> some View {
        LabeledContent(label, value: count.formatted())
    }

    private static func exclusionLabel(_ reason: String) -> String {
        reason.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
#endif
