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

    typealias AuthoritySnapshotProvider = @MainActor () async throws -> HouseholdZoneRecoveryAuthoritySnapshot
    typealias AuthorityValidator = @MainActor (HouseholdZoneRecoveryAuthoritySnapshot) -> Bool
    typealias AnalysisProvider = @MainActor (
        HouseholdZoneRecoveryAuthoritySnapshot,
        [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryProvenanceDecision],
        [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryDecision]
    ) async throws -> HouseholdZoneRecoveryAnalysis

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.simmersmith.ios",
        category: "HouseholdZoneRecovery")

    private let isRecoveryAvailable: () -> Bool
    private let authoritySnapshot: AuthoritySnapshotProvider
    private let authorityIsCurrent: AuthorityValidator
    private let analysisProvider: AnalysisProvider
    private let manifestStore: any HouseholdZoneRecoveryManifestStoring
    private var analysisTask: Task<Void, Never>?
    private var requestGeneration = 0

    private(set) var state: State = .idle

    init(
        isRecoveryAvailable: @escaping () -> Bool,
        authoritySnapshot: @escaping AuthoritySnapshotProvider,
        authorityIsCurrent: @escaping AuthorityValidator,
        analyze: @escaping AnalysisProvider,
        manifestStore: any HouseholdZoneRecoveryManifestStoring
    ) {
        self.isRecoveryAvailable = isRecoveryAvailable
        self.authoritySnapshot = authoritySnapshot
        self.authorityIsCurrent = authorityIsCurrent
        analysisProvider = analyze
        self.manifestStore = manifestStore
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
            manifestStore: HouseholdZoneRecoveryManifestStore())
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
        guard isRecoveryAvailable() else {
            state = .failed("Recovery analysis is unavailable in this build.")
            return
        }
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
            return
        }
        _ = try manifestStore.save(preview.manifest)
    }

    private func authorityChangedDuringReview() {
        try? manifestStore.remove()
        state = .failed("The household session changed during recovery review.")
        Self.logger.error("review_authority_changed")
    }

    private func failStorageOrDecision() {
        try? manifestStore.remove()
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
        .onDisappear { viewModel.cancelAnalysis() }
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
            Text("There is no apply action in this build. The complete manifest stays in Application Support only after every required decision is made.")
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
