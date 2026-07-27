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

    func save(_ manifest: HouseholdZoneRecoveryManifest) throws -> HouseholdZoneRecoveryStoredArtifact {
        let artifact = try HouseholdZoneRecoveryStoredArtifact(
            canonicalManifestBytes: manifest.canonicalJSONBytes(),
            digest: manifest.digest())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(try encoder.encode(artifact), to: fileURL)
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
    }
}

@MainActor
protocol HouseholdZoneRecoveryApplyBoundary:
    AnyObject,
    HouseholdZoneRecoveryApplySessionFence
{
    func unparkNormalSession() async
}

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
    typealias ParkNormalSession = @MainActor (
        HouseholdZoneRecoveryAuthoritySnapshot
    ) async throws -> any HouseholdZoneRecoveryApplyBoundary
    typealias ApplyPreparationProvider = @MainActor (
        HouseholdZoneRecoveryStoredArtifact,
        HouseholdZoneRecoveryAuthoritySnapshot,
        any HouseholdZoneRecoveryApplyBoundary
    ) async throws -> any HouseholdZoneRecoveryApplying

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.simmersmith.ios",
        category: "HouseholdZoneRecovery")

    private let isRecoveryAvailable: () -> Bool
    private let authoritySnapshot: AuthoritySnapshotProvider
    private let authorityIsCurrent: AuthorityValidator
    private let analysisProvider: AnalysisProvider
    private let manifestStore: any HouseholdZoneRecoveryManifestStoring
    private let parkNormalSession: ParkNormalSession?
    private let prepareApply: ApplyPreparationProvider?
    private var approvedAuthority: HouseholdZoneRecoveryAuthoritySnapshot?
    private var analysisTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var requestGeneration = 0

    private(set) var state: State = .idle
    private(set) var applyState: ApplyState = .idle
    private(set) var storedApprovalDigest: String?
    private(set) var localConflictIdentity: HouseholdZoneRecoveryIdentity?
    var typedDigestConfirmation = ""

    init(
        isRecoveryAvailable: @escaping () -> Bool,
        authoritySnapshot: @escaping AuthoritySnapshotProvider,
        authorityIsCurrent: @escaping AuthorityValidator,
        analyze: @escaping AnalysisProvider,
        manifestStore: any HouseholdZoneRecoveryManifestStoring
        ,
        parkNormalSession: ParkNormalSession? = nil,
        prepareApply: ApplyPreparationProvider? = nil
    ) {
        self.isRecoveryAvailable = isRecoveryAvailable
        self.authoritySnapshot = authoritySnapshot
        self.authorityIsCurrent = authorityIsCurrent
        analysisProvider = analyze
        self.manifestStore = manifestStore
        self.parkNormalSession = parkNormalSession
        self.prepareApply = prepareApply
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
            parkNormalSession: { try await appState.parkNormalSessionForHouseholdZoneRecovery($0) },
            prepareApply: { artifact, authority, boundary in
                try await HouseholdZoneRecoveryProductionApplyOperation.prepare(
                    artifact: artifact,
                    authority: authority,
                    boundary: boundary)
            })
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
            return "Recovery stopped safely after \(completed) of \(total) batches. Resume manually with the same digest."
        case .conflict:
            return "Recovery stopped because target data changed."
        case .verifiedCompletion(let completed, let total):
            return "Verified recovery completion: \(completed) of \(total) batches."
        case .failed(let message):
            return message
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
            applyState = .failed("Recovery apply is unavailable in this build.")
            return
        }
        do {
            guard let artifact = try manifestStore.load() else {
                storedApprovalDigest = nil
                approvedAuthority = nil
                applyState = .idle
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
            applyState = .idle
        } catch {
            storedApprovalDigest = nil
            approvedAuthority = nil
            applyState = .failed("The stored recovery approval could not be verified.")
            Self.logger.error("apply_approval_load_failed")
        }
    }

    func requestApplyConfirmation() {
        guard canRequestApplyConfirmation else { return }
        applyState = .awaitingDestructiveConfirmation
    }

    func cancelApplyConfirmation() {
        guard applyState == .awaitingDestructiveConfirmation else { return }
        applyState = .idle
    }

    func confirmApply() {
        guard applyState == .awaitingDestructiveConfirmation,
              applyTask == nil else { return }
        applyState = .preparing
        applyTask = Task { [weak self] in
            await self?.performApply()
        }
    }

    func cancelApply() {
        applyTask?.cancel()
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
        applyState = .idle
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

    private func performApply() async {
        var boundary: (any HouseholdZoneRecoveryApplyBoundary)?
        var completedBatchCount = 0
        var totalBatchCount = 0
        do {
            guard let confirmedDigest = storedApprovalDigest,
                  typedDigestConfirmation == confirmedDigest,
                  let approvedAuthority,
                  let parkNormalSession,
                  let prepareApply,
                  let artifact = try manifestStore.load(),
                  artifact.digest == confirmedDigest else {
                throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
            }
            let manifest = try artifact.manifest()
            guard manifest.accountFingerprint == approvedAuthority.accountFingerprint,
                  manifest.sourceScope == approvedAuthority.sourceScope,
                  manifest.targetScope == approvedAuthority.targetScope else {
                throw HouseholdZoneRecoveryViewModelError.invalidStoredArtifact
            }

            let currentAuthority = try await authoritySnapshot()
            guard currentAuthority == approvedAuthority,
                  authorityIsCurrent(currentAuthority) else {
                throw HouseholdZoneRecoveryViewModelError.invalidAuthority
            }
            try Task.checkCancellation()

            let parkedBoundary = try await parkNormalSession(currentAuthority)
            boundary = parkedBoundary
            try Task.checkCancellation()

            let operation = try await prepareApply(artifact, currentAuthority, parkedBoundary)
            totalBatchCount = operation.totalBatchCount
            var shouldContinue = true
            while shouldContinue {
                if Task.isCancelled {
                    applyState = .resumableStop(
                        completedBatchCount: completedBatchCount,
                        totalBatchCount: totalBatchCount)
                    break
                }
                applyState = .applying(
                    completedBatchCount: completedBatchCount,
                    totalBatchCount: totalBatchCount)
                let result = await operation.apply(maximumBatchCount: 1)
                switch result {
                case .preflightRejected:
                    applyState = .failed(
                        "Recovery apply stopped before the next write because its safety checks changed.")
                    shouldContinue = false
                case .progress(let receipt):
                    let nextCompleted = receipt.completedBatchDigests.count
                    guard nextCompleted > completedBatchCount else {
                        applyState = .resumableStop(
                            completedBatchCount: completedBatchCount,
                            totalBatchCount: totalBatchCount)
                        shouldContinue = false
                        break
                    }
                    completedBatchCount = nextCompleted
                    applyState = .applying(
                        completedBatchCount: completedBatchCount,
                        totalBatchCount: totalBatchCount)
                    await Task.yield()
                case .resumableStop(let receipt, _):
                    completedBatchCount = receipt?.completedBatchDigests.count ?? completedBatchCount
                    applyState = .resumableStop(
                        completedBatchCount: completedBatchCount,
                        totalBatchCount: totalBatchCount)
                    shouldContinue = false
                case .conflict(let receipt, let identity):
                    completedBatchCount = receipt?.completedBatchDigests.count ?? completedBatchCount
                    localConflictIdentity = identity
                    applyState = .conflict(
                        completedBatchCount: completedBatchCount,
                        totalBatchCount: totalBatchCount)
                    shouldContinue = false
                case .verifiedCompletion(let receipt):
                    completedBatchCount = receipt.completedBatchDigests.count
                    applyState = .verifiedCompletion(
                        completedBatchCount: completedBatchCount,
                        totalBatchCount: totalBatchCount)
                    shouldContinue = false
                }
            }
            Self.logger.info(
                "apply_stopped completed=\(completedBatchCount, privacy: .public) total=\(totalBatchCount, privacy: .public)")
        } catch is CancellationError {
            applyState = .resumableStop(
                completedBatchCount: completedBatchCount,
                totalBatchCount: totalBatchCount)
            Self.logger.info(
                "apply_cancelled completed=\(completedBatchCount, privacy: .public) total=\(totalBatchCount, privacy: .public)")
        } catch HouseholdZoneRecoveryViewModelError.invalidAuthority {
            applyState = .failed("The household session changed before recovery apply.")
            Self.logger.error("apply_authority_changed")
        } catch HouseholdZoneRecoveryViewModelError.invalidStoredArtifact {
            applyState = .failed("The approved recovery manifest changed. Review it again.")
            Self.logger.error("apply_artifact_changed")
        } catch {
            applyState = Task.isCancelled
                ? .resumableStop(
                    completedBatchCount: completedBatchCount,
                    totalBatchCount: totalBatchCount)
                : .failed("Recovery apply stopped safely without changing the source.")
            Self.logger.error("apply_failed")
        }
        if let boundary {
            await boundary.unparkNormalSession()
        }
        applyTask = nil
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
        applyState = .idle
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
            viewModel.cancelApply()
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
