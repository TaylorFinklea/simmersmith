#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import Testing
@testable import HouseholdSync

@Suite("HouseholdZoneRecoveryApplierTests", .serialized)
struct HouseholdZoneRecoveryApplierTests {
    @Test("manifest approval mismatch rejects before any target write")
    func manifestApprovalMismatchIsNoWrite() async throws {
        let fixture = try Fixture()
        let result = await fixture.applier(
            approval: HouseholdZoneRecoveryApproval(manifestDigest: "not-approved")
        ).apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .manifest(.approvalMismatch),
            HouseholdZoneRecoveryApplyDiagnostic(
                category: .manifestRejected, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("unresolved approval decisions reject before any target write")
    func unresolvedDecisionsAreNoWrite() async throws {
        let fixture = try Fixture()
        let unresolved = try HouseholdZoneRecoveryManifest(
            accountFingerprint: fixture.manifest.accountFingerprint,
            sourceScope: fixture.manifest.sourceScope,
            targetScope: fixture.manifest.targetScope,
            sourceInputFingerprint: fixture.manifest.sourceInputFingerprint,
            targetInputFingerprint: fixture.manifest.targetInputFingerprint,
            entries: [],
            exclusions: [],
            unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry(
                entry: fixture.manifest.entries[0])])
        let result = await fixture.applier(
            manifest: unresolved,
            approval: HouseholdZoneRecoveryApproval(manifestDigest: try unresolved.digest())
        ).apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .manifest(.unresolvedProvenance),
            HouseholdZoneRecoveryApplyDiagnostic(
                category: .manifestRejected, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("changed source or target approval fingerprint rejects before any write", arguments: [true, false])
    func changedInputFingerprintsAreNoWrite(changeSource: Bool) async throws {
        let fixture = try Fixture()
        if changeSource {
            fixture.transport.sourceFingerprint = "changed-source"
        } else {
            fixture.transport.targetFingerprint = "changed-target"
        }

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            changeSource ? .sourceInputChanged : .targetInputChanged,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: changeSource ? .sourceInputChanged : .targetInputChanged,
                batchIndex: nil,
                batchRecordCount: nil)))
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }
    @Test("every preflight rejection cause is distinguishable on device and leaks no record names")
    func preflightRejectionCausesAreDistinguishable() async throws {
        func category(
            _ result: HouseholdZoneRecoveryApplyResult
        ) throws -> HouseholdZoneRecoveryApplyDiagnosticCategory {
            guard case .preflightRejected(_, let diagnostic) = result else {
                throw PreflightProbeError.notPreflightRejected
            }
            return try #require(diagnostic).category
        }

        let mismatched = try Fixture()
        let mismatchedCategory = try category(await mismatched.applier(
            approval: HouseholdZoneRecoveryApproval(manifestDigest: "not-approved")
        ).apply(maximumBatchCount: 1))

        let changedSource = try Fixture()
        changedSource.transport.sourceFingerprint = "changed-source"
        let sourceCategory = try category(
            await changedSource.applier().apply(maximumBatchCount: 1))

        let changedTarget = try Fixture()
        changedTarget.transport.targetFingerprint = "changed-target"
        let targetCategory = try category(
            await changedTarget.applier().apply(maximumBatchCount: 1))

        let revoked = try Fixture()
        revoked.fence.sessionAuthority.revoke()
        let revokedCategory = try category(
            await revoked.applier().apply(maximumBatchCount: 1))

        let unparked = try Fixture()
        unparked.fence.isParked = false
        let unparkedCategory = try category(
            await unparked.applier().apply(maximumBatchCount: 1))

        let observed = [
            mismatchedCategory,
            sourceCategory,
            targetCategory,
            revokedCategory,
            unparkedCategory,
        ]
        #expect(observed == [
            .manifestRejected,
            .sourceInputChanged,
            .targetInputChanged,
            .authorityChanged,
            .sessionParked,
        ])
        #expect(Set(observed).count == observed.count)
        let privateName = mismatched.manifest.entries[0].identity.source.recordName
        for category in observed {
            #expect(!category.rawValue.contains(privateName))
        }
    }

    private enum PreflightProbeError: Error {
        case notPreflightRejected
    }


    @Test("account epoch owner private and distinct-zone authority evidence is exact and no-write", arguments: [
        AuthorityMutation.account,
        .epoch,
        .ownerRole,
        .privateDatabase,
        .equalZones,
        .targetZone,
    ])
    func changedAuthorityEvidenceIsNoWrite(mutation: AuthorityMutation) async throws {
        let fixture = try Fixture()
        fixture.fence.snapshot = mutation.apply(to: fixture.authority)

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .authorityChanged,
            HouseholdZoneRecoveryApplyDiagnostic(category: .authorityChanged, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("revoked existing session authority or unparked normal session is no-write", arguments: [true, false])
    func sessionFencePreflightIsNoWrite(revokeAuthority: Bool) async throws {
        let fixture = try Fixture()
        if revokeAuthority {
            fixture.fence.sessionAuthority.revoke()
        } else {
            fixture.fence.isParked = false
        }

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            revokeAuthority ? .notAuthoritative : .normalSessionNotParked,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: revokeAuthority ? .authorityChanged : .sessionParked,
                batchIndex: nil,
                batchRecordCount: nil)))
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("fingerprints and parked state are rechecked immediately before the first write")
    func immediateFirstWriteFenceIsNoWrite() async throws {
        let fixture = try Fixture()
        fixture.transport.afterFingerprint = { zoneID in
            if zoneID == fixture.targetZone,
               fixture.transport.fingerprintCalls.filter({ $0 == fixture.targetZone }).count == 2 {
                fixture.fence.isParked = false
            }
        }

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .normalSessionNotParked,
            HouseholdZoneRecoveryApplyDiagnostic(category: .sessionParked, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.fingerprintCalls.filter { $0 == fixture.sourceZone }.count == 2)
        #expect(fixture.transport.fingerprintCalls.filter { $0 == fixture.targetZone }.count == 2)
        #expect(fixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("each data batch atomically saves only target records with its receipt and never deletes")
    func targetOnlyAtomicApplyAndVerification() async throws {
        let fixture = try Fixture(shape: .dependency)

        let result = await fixture.applier().apply(maximumBatchCount: 10)

        guard case .verifiedCompletion(let receipt) = result else {
            Issue.record("expected verified completion, got \(result)")
            return
        }
        #expect(receipt.isTerminalComplete)
        #expect(receipt.completedAt != nil)
        #expect(fixture.transport.committedSaves.count == 3)
        for batch in fixture.transport.committedSaves.dropLast() {
            #expect(batch.last?.recordType == HouseholdZoneRecoveryReceipt.recordType)
            #expect(batch.dropLast().allSatisfy { $0.recordID.zoneID == fixture.targetZone })
            #expect(batch.dropLast().allSatisfy { $0.recordID.zoneID != fixture.sourceZone })
        }
        #expect(fixture.transport.committedSaves.last?.count == 1)
        #expect(fixture.transport.committedSaves.last?.first?.recordType
            == HouseholdZoneRecoveryReceipt.recordType)
        #expect(fixture.transport.deleteCallCount == 0)

        let child = try #require(fixture.transport.records[fixture.targetRecordID("child")])
        let references = try #require(child["baseRecipe"] as? [CKRecord.Reference])
        #expect(references.map(\.recordID.zoneID) == [fixture.targetZone])
        #expect(try fixture.plan.targetApplicationDigest(
            records: fixture.targetApplicationRecords())
            == fixture.plan.expectedFinalTargetApplicationDigest)
    }

    @Test("transient and partial failures stop without progress and retry the exact batch", arguments: [
        HouseholdZoneRecoveryApplyTransportError.transient,
        .partialFailure,
    ])
    func resumableTransportFailureRetriesBatch(
        failure: HouseholdZoneRecoveryApplyTransportError
    ) async throws {
        let fixture = try Fixture()
        fixture.transport.saveBehaviors = [.failure(failure), .success, .success]

        let stopped = await fixture.applier().apply(maximumBatchCount: 1)
        #expect(stopped == .resumableStop(
            nil,
            failure == .transient ? .transientTransport : .partialFailure,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: failure == .transient ? .networkUnavailable : .partialFailure,
                batchIndex: 0,
                batchRecordCount: fixture.plan.batches[0].records.count)))
        #expect(fixture.transport.records[fixture.targetRecordID("recipe-a")] == nil)

        let resumed = await fixture.applier().apply(maximumBatchCount: 1)
        guard case .verifiedCompletion = resumed else {
            Issue.record("expected resumed verification, got \(resumed)")
            return
        }
        #expect(fixture.transport.atomicSaveAttempts.count == 3)
        #expect(fixture.transport.committedSaves.count == 2)
    }

    @Test("raw CloudKit read and TOCTOU write errors use the apply taxonomy")
    func rawCloudKitErrorsAreClassified() async throws {
        let readFixture = try Fixture()
        readFixture.transport.pageError = CKError(.networkFailure)
        #expect(await readFixture.applier().apply(maximumBatchCount: 1)
            == .resumableStop(
                nil,
                .transientTransport,
                HouseholdZoneRecoveryApplyDiagnostic(
                    category: .networkUnavailable, batchIndex: nil, batchRecordCount: nil)))
        #expect(readFixture.transport.atomicSaveAttempts.isEmpty)

        let writeFixture = try Fixture()
        writeFixture.transport.saveBehaviors = [
            .failure(CKError(.serverRecordChanged)),
        ]
        guard case .conflict = await writeFixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("serverRecordChanged was not mapped to conflict")
            return
        }
        #expect(writeFixture.transport.committedSaves.isEmpty)
    }

    @Test("a CloudKit limitExceeded write failure surfaces its diagnostic category, batch index, and record count, with no writes at all")
    func limitExceededWriteReportsDiagnostic() async throws {
        let fixture = try Fixture(shape: .dependency)
        fixture.transport.saveBehaviors = [.failure(CKError(.limitExceeded))]

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .resumableStop(nil, .permanentTransport, let diagnostic?) = result else {
            Issue.record("expected resumable stop with diagnostic, got \(result)")
            return
        }
        #expect(diagnostic.category == .limitExceeded)
        #expect(diagnostic.batchIndex == 0)
        #expect(diagnostic.batchRecordCount == fixture.plan.batches[0].records.count)
        #expect(fixture.transport.committedSaves.isEmpty)
    }

    @Test("a later batch's write failure reports that batch's own index and record count")
    func laterBatchFailureReportsOwnIndex() async throws {
        let fixture = try Fixture(shape: .dependency)
        fixture.transport.saveBehaviors = [.success, .failure(CKError(.limitExceeded))]

        guard case .progress = await fixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("first batch did not make progress")
            return
        }

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .resumableStop(let receipt?, .permanentTransport, let diagnostic?) = result else {
            Issue.record("expected resumable stop with diagnostic, got \(result)")
            return
        }
        #expect(receipt.completedBatchDigests == [fixture.plan.batches[0].digest])
        #expect(diagnostic.category == .limitExceeded)
        #expect(diagnostic.batchIndex == 1)
        #expect(diagnostic.batchRecordCount == fixture.plan.batches[1].records.count)
    }

    @Test("transport-layer read failures map to stable apply stops")
    func transportReadErrorsAreClassified() async throws {
        let pageFailures: [
            (
                HouseholdZoneRecoveryTransportError,
                HouseholdZoneRecoveryApplyStopReason,
                HouseholdZoneRecoveryApplyDiagnosticCategory
            )
        ] = [
            (.partialFailure, .partialFailure, .partialFailure),
            (.mismatchedZone, .zoneChanged, .zoneChanged),
            (.missingZoneResult, .permanentTransport, .other),
        ]
        for (error, expected, expectedCategory) in pageFailures {
            let fixture = try Fixture()
            fixture.transport.pageError = error
            #expect(await fixture.applier().apply(maximumBatchCount: 1)
                == .resumableStop(
                    nil,
                    expected,
                    HouseholdZoneRecoveryApplyDiagnostic(
                        category: expectedCategory,
                        batchIndex: nil,
                        batchRecordCount: nil)))
            #expect(fixture.transport.atomicSaveAttempts.isEmpty)
        }

        let fingerprintFixture = try Fixture()
        fingerprintFixture.transport.fingerprintError = .invalidCursor
        #expect(await fingerprintFixture.applier().apply(maximumBatchCount: 1)
            == .resumableStop(
                nil,
                .permanentTransport,
                HouseholdZoneRecoveryApplyDiagnostic(category: .other, batchIndex: nil, batchRecordCount: nil)))
        #expect(fingerprintFixture.transport.atomicSaveAttempts.isEmpty)
    }

    @Test("bounded apply resumes from the receipt and does not rerun approval fingerprints")
    func boundedProgressResumesFromReceipt() async throws {
        let fixture = try Fixture(shape: .dependency)

        let first = await fixture.applier().apply(maximumBatchCount: 1)
        guard case .progress(let progressReceipt) = first else {
            Issue.record("expected progress, got \(first)")
            return
        }
        #expect(progressReceipt.completedBatchDigests == [fixture.plan.batches[0].digest])
        let fingerprintCallCount = fixture.transport.fingerprintCalls.count

        let second = await fixture.applier().apply(maximumBatchCount: 1)
        guard case .verifiedCompletion(let terminalReceipt) = second else {
            Issue.record("expected verified completion, got \(second)")
            return
        }
        #expect(terminalReceipt.completedBatchDigests == fixture.plan.batches.map(\.digest))
        #expect(fixture.transport.fingerprintCalls.count == fingerprintCallCount)
        #expect(fixture.transport.committedSaves.count == 3)
    }

    @Test("authority account and epoch are rechecked after every awaited batch", arguments: [true, false])
    func authorityChangeBetweenBatchesStops(changeAccount: Bool) async throws {
        let fixture = try Fixture(shape: .dependency)
        fixture.transport.afterCommittedSave = { records in
            guard records.contains(where: { $0.recordType != HouseholdZoneRecoveryReceipt.recordType }) else {
                return
            }
            fixture.fence.snapshot = changeAccount
                ? AuthorityMutation.account.apply(to: fixture.authority)
                : AuthorityMutation.epoch.apply(to: fixture.authority)
        }

        let result = await fixture.applier().apply(maximumBatchCount: 2)

        guard case .resumableStop(let receipt?, .authorityChanged, let diagnostic?) = result else {
            Issue.record("expected authority stop, got \(result)")
            return
        }
        #expect(receipt.completedBatchDigests == [fixture.plan.batches[0].digest])
        #expect(fixture.transport.committedSaves.count == 1)
        #expect(diagnostic.category == .authorityChanged)
    }

    @Test("an unparked normal session mid-apply surfaces the sessionParked diagnostic category")
    func parkedSessionDuringApplySurfacesCategory() async throws {
        let fixture = try Fixture(shape: .dependency)
        fixture.transport.afterCommittedSave = { records in
            guard records.contains(where: { $0.recordType != HouseholdZoneRecoveryReceipt.recordType }) else {
                return
            }
            fixture.fence.isParked = false
        }

        let result = await fixture.applier().apply(maximumBatchCount: 2)

        guard case .resumableStop(let receipt?, .normalSessionNotParked, let diagnostic?) = result else {
            Issue.record("expected parked-session stop, got \(result)")
            return
        }
        #expect(receipt.completedBatchDigests == [fixture.plan.batches[0].digest])
        #expect(fixture.transport.committedSaves.count == 1)
        #expect(diagnostic.category == .sessionParked)
    }

    @Test("target application divergence between batches is a conflict with no further write")
    func changedTargetBetweenBatchesStops() async throws {
        let fixture = try Fixture(shape: .dependency)
        guard case .progress = await fixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("first batch did not make progress")
            return
        }
        let parent = try #require(fixture.transport.records[fixture.targetRecordID("parent")])
        parent["name"] = "changed outside recovery" as CKRecordValue
        let committedBeforeResume = fixture.transport.committedSaves.count

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .conflict = result else {
            Issue.record("expected target conflict, got \(result)")
            return
        }
        #expect(fixture.transport.committedSaves.count == committedBeforeResume)
    }

    @Test("target snapshot pagination replaces per-identity reads")
    func targetSnapshotUsesBoundedPageCalls() async throws {
        let fixture = try Fixture()
        for index in 0..<641 {
            let record = CKRecord(
                recordType: "Unrelated",
                recordID: CKRecord.ID(
                    recordName: "unrelated-\(index)",
                    zoneID: fixture.targetZone))
            fixture.transport.records[record.recordID] = record
        }
        fixture.transport.pageSize = 100

        guard case .verifiedCompletion = await fixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("expected verified completion")
            return
        }
        #expect(fixture.transport.recordCalls.isEmpty)
        #expect(fixture.transport.pageCalls.count < 50)
    }

    @Test("terminal verification refetches every approved identity and refuses a divergent digest")
    func completedVerificationRefetchesAndStopsDivergence() async throws {
        let fixture = try Fixture()
        fixture.transport.afterCommittedSave = { records in
            guard records.contains(where: { $0.recordType == "Recipe" }),
                  let record = fixture.transport.records[fixture.targetRecordID("recipe-a")] else {
                return
            }
            record["name"] = "corrupted after acknowledgement" as CKRecordValue
        }

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .conflict(_, let identity?, _) = result else {
            Issue.record("expected verification conflict identity, got \(result)")
            return
        }
        #expect(identity == fixture.manifest.entries[0].identity)
        #expect(!fixture.transport.pageCalls.isEmpty)
        #expect(fixture.transport.committedSaves.count == 1)
        let persisted = try fixture.persistedReceipt()
        let progress = try #require(persisted)
        #expect(!progress.isTerminalComplete)
    }

    @Test("staged assets remain readable through atomic CloudKit acknowledgement")
    func assetLifetimeExtendsThroughAcknowledgement() async throws {
        let fixture = try Fixture(shape: .asset)
        var observedAssetDuringAcknowledgement = false
        fixture.transport.beforeSave = { records in
            for record in records {
                guard let asset = record["imageAsset"] as? CKAsset else { continue }
                let fileURL = try #require(asset.fileURL)
                #expect(FileManager.default.fileExists(atPath: fileURL.path))
                #expect(!(try Data(contentsOf: fileURL)).isEmpty)
                observedAssetDuringAcknowledgement = true
            }
        }

        let result = await fixture.applier().apply(maximumBatchCount: 10)

        guard case .verifiedCompletion = result else {
            Issue.record("expected verified asset completion, got \(result)")
            return
        }
        #expect(observedAssetDuringAcknowledgement)
        for asset in fixture.plan.records.flatMap(\.assets) {
            #expect(asset.lifetime == .untilCloudKitAcknowledgement)
            #expect(!FileManager.default.fileExists(atPath: asset.fileURL.path))
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.plan.stagingDirectoryURL.path))
    }

    @Test("asset staging survives bounded progress and resumable stop")
    func assetCleanupWaitsForTerminalAcknowledgement() async throws {
        let progressFixture = try Fixture(shape: .asset)
        guard case .progress = await progressFixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("expected bounded progress")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: progressFixture.plan.stagingDirectoryURL.path))

        let stopFixture = try Fixture(shape: .asset)
        stopFixture.transport.saveBehaviors = [
            .failure(HouseholdZoneRecoveryApplyTransportError.transient),
        ]
        guard case .resumableStop = await stopFixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("expected resumable stop")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: stopFixture.plan.stagingDirectoryURL.path))
    }

    @Test("a stale legacy-topology receipt yields incompatibleReceipt and performs no write")
    func staleLegacyTopologyReceiptIsIncompatible() async throws {
        let fixture = try Fixture(shape: .dependency)
        let base = fixture.plan.initialReceipt
        let legacyReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: base.manifestDigest,
            sourceInputFingerprint: base.sourceInputFingerprint,
            initialTargetInputFingerprint: base.initialTargetInputFingerprint,
            targetZoneOwnerName: base.targetZoneOwnerName,
            targetZoneName: base.targetZoneName,
            approvedIdentityActions: base.approvedIdentityActions,
            batchDigests: base.batchDigests.map { $0 + "-legacy-topology" },
            targetApplicationDigests: base.targetApplicationDigests,
            targetRecordApplicationDigestProgress: base.targetRecordApplicationDigestProgress)
        let legacyRecord = legacyReceipt.makeRecord()
        fixture.transport.records[legacyRecord.recordID] = legacyRecord

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .invalidReceipt,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: .incompatibleReceipt, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.committedSaves.isEmpty)
    }

    @Test("a CKError permissionFailure write failure surfaces the permissionDenied diagnostic with batch index and record count")
    func permissionFailureWriteReportsDiagnostic() async throws {
        let fixture = try Fixture(shape: .dependency)
        fixture.transport.saveBehaviors = [.failure(CKError(.permissionFailure))]

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .resumableStop(nil, .permissionDenied, let diagnostic?) = result else {
            Issue.record("expected resumable stop with permissionDenied diagnostic, got \(result)")
            return
        }
        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.batchIndex == 0)
        #expect(diagnostic.batchRecordCount == fixture.plan.batches[0].records.count)
        #expect(fixture.transport.committedSaves.isEmpty)
    }

    @Test("a server receipt record carrying a foreign key fails closed with incompatibleReceipt and skips the corrupted write")
    func atomicBatchReceiptForeignKeyFailsClosed() async throws {
        let fixture = try Fixture(shape: .dependency)
        var corruptionApplied = false
        fixture.transport.afterCommittedSave = { records in
            guard !corruptionApplied,
                  let receiptRecord = records.first(where: {
                      $0.recordType == HouseholdZoneRecoveryReceipt.recordType
                  }) else { return }
            corruptionApplied = true
            receiptRecord["foreignKey"] = "leaked-value" as CKRecordValue
        }

        let result = await fixture.applier().apply(maximumBatchCount: 10)

        #expect(result == .preflightRejected(
            .invalidReceipt,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: .incompatibleReceipt, batchIndex: nil, batchRecordCount: nil)))
        #expect(corruptionApplied)
        #expect(fixture.transport.committedSaves.count == 1)
    }

    @Test("an unparseable or unsupported-version receipt record reports incompatibleReceipt rather than a nil diagnostic")
    func unsupportedReceiptVersionIsIncompatible() async throws {
        let fixture = try Fixture(shape: .dependency)
        let malformedRecord = fixture.plan.initialReceipt.makeRecord()
        malformedRecord["formatVersion"] = 999 as CKRecordValue
        fixture.transport.records[malformedRecord.recordID] = malformedRecord

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        #expect(result == .preflightRejected(
            .invalidReceipt,
            HouseholdZoneRecoveryApplyDiagnostic(
                category: .incompatibleReceipt, batchIndex: nil, batchRecordCount: nil)))
        #expect(fixture.transport.committedSaves.isEmpty)
    }

    @Test("a well-formed matching receipt round-trips through the atomic-batch overlay and the write proceeds unchanged")
    func matchingReceiptOverlayRoundTripsAcrossBatches() async throws {
        let fixture = try Fixture(shape: .dependency)
        let receiptID = CKRecord.ID(
            recordName: HouseholdZoneRecoveryReceipt.recordName(manifestDigest: fixture.plan.manifestDigest),
            zoneID: fixture.targetZone)

        guard case .progress(let afterFirst) = await fixture.applier().apply(maximumBatchCount: 1) else {
            Issue.record("expected progress after first batch")
            return
        }
        #expect(afterFirst.completedBatchDigests == [fixture.plan.batches[0].digest])
        let persistedAfterFirst = try #require(fixture.transport.records[receiptID])
        #expect(try HouseholdZoneRecoveryReceipt(record: persistedAfterFirst) == afterFirst)

        let result = await fixture.applier().apply(maximumBatchCount: 1)

        guard case .verifiedCompletion(let terminal) = result else {
            Issue.record("expected verified completion, got \(result)")
            return
        }
        #expect(terminal.completedBatchDigests == fixture.plan.batches.map(\.digest))
        #expect(fixture.transport.committedSaves.count == 3)
    }
}

enum AuthorityMutation: Sendable {
    case account
    case epoch
    case ownerRole
    case privateDatabase
    case equalZones
    case targetZone

    func apply(
        to snapshot: HouseholdZoneRecoveryApplyAuthoritySnapshot
    ) -> HouseholdZoneRecoveryApplyAuthoritySnapshot {
        var accountFingerprint = snapshot.accountFingerprint
        var source = snapshot.sourceScope
        var target = snapshot.targetScope
        var epoch = snapshot.sessionEpoch
        switch self {
        case .account:
            accountFingerprint = "other-account"
        case .epoch:
            epoch += 1
        case .ownerRole:
            target = scope(
                basedOn: target,
                role: .participant,
                databaseScope: .shared)
        case .privateDatabase:
            source = scope(basedOn: source, databaseScope: .shared)
        case .equalZones:
            target = source
        case .targetZone:
            target = scope(basedOn: target, zoneName: "other-target")
        }
        return HouseholdZoneRecoveryApplyAuthoritySnapshot(
            accountFingerprint: accountFingerprint,
            sourceScope: source,
            targetScope: target,
            sessionEpoch: epoch)
    }

    private func scope(
        basedOn original: MirrorScope,
        zoneName: String? = nil,
        role: MirrorRole? = nil,
        databaseScope: MirrorDatabaseScope? = nil
    ) -> MirrorScope {
        MirrorScope(
            accountRecordName: original.accountRecordName,
            zoneOwnerName: original.zoneOwnerName,
            zoneName: zoneName ?? original.zoneName,
            householdID: original.householdID,
            role: role ?? original.role,
            databaseScope: databaseScope ?? original.databaseScope,
            containerIdentifier: original.containerIdentifier,
            formatVersion: original.formatVersion)
    }
}

private final class RecordingApplyTransport: HouseholdZoneRecoveryApplyTransport, @unchecked Sendable {
    enum SaveBehavior {
        case success
        case failure(any Error)
    }

    var records: [CKRecord.ID: CKRecord] = [:]
    var sourceFingerprint = "source-input"
    var targetFingerprint = "target-input"
    var saveBehaviors: [SaveBehavior] = []
    var beforeSave: (([CKRecord]) throws -> Void)?
    var afterCommittedSave: (([CKRecord]) -> Void)?
    var afterFingerprint: ((CKRecordZone.ID) -> Void)?
    var pageError: (any Error)?
    var fingerprintError: HouseholdZoneRecoveryTransportError?
    var pageSize = Int.max

    private(set) var atomicSaveAttempts: [[CKRecord]] = []
    private(set) var committedSaves: [[CKRecord]] = []
    private(set) var fingerprintCalls: [CKRecordZone.ID] = []
    private(set) var recordCalls: [CKRecord.ID] = []
    private(set) var pageCalls: [(CKRecordZone.ID, String?)] = []
    private(set) var deleteCallCount = 0

    func fetchRecordPage(
        in zoneID: CKRecordZone.ID,
        after cursor: HouseholdZoneRecoveryPageCursor?,
        desiredKeys: [String]?
    ) async throws -> HouseholdZoneRecoveryRecordPage {
        pageCalls.append((zoneID, cursor?.identifier))
        if let pageError { throw pageError }
        let matching = records.values
            .filter { $0.recordID.zoneID == zoneID }
            .sorted { $0.recordID.recordName < $1.recordID.recordName }
        let start = cursor.flatMap { Int($0.identifier) } ?? 0
        let end = min(start + pageSize, matching.count)
        let next = end < matching.count
            ? HouseholdZoneRecoveryPageCursor(identifier: String(end))
            : nil
        return HouseholdZoneRecoveryRecordPage(
            zoneID: zoneID,
            records: Array(matching[start..<end]),
            nextCursor: next)
    }

    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        recordCalls.append(recordID)
        return records[recordID]
    }

    func assetPayload(for asset: CKAsset) async throws -> HouseholdZoneRecoveryAssetPayload {
        guard let url = asset.fileURL else { throw HouseholdZoneRecoveryTransportError.unreadableAsset }
        let bytes = try Data(contentsOf: url)
        return HouseholdZoneRecoveryAssetPayload(
            bytes: bytes,
            digest: ShadowMirrorDigest.sha256(bytes))
    }

    func inputFingerprint(for zoneID: CKRecordZone.ID) async throws -> String {
        fingerprintCalls.append(zoneID)
        if let fingerprintError { throw fingerprintError }
        let result = zoneID.zoneName == HouseholdZoneRecoveryManifest.reservedSourceZoneName
            ? sourceFingerprint
            : targetFingerprint
        afterFingerprint?(zoneID)
        return result
    }

    func saveRecordsAtomically(
        _ records: [CKRecord],
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        try beforeSave?(records)
        atomicSaveAttempts.append(records)
        let behavior = saveBehaviors.isEmpty ? .success : saveBehaviors.removeFirst()
        if case .failure(let error) = behavior { throw error }
        guard records.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
            throw HouseholdZoneRecoveryApplyTransportError.invalidResponse
        }
        let saved = records.map { $0.copy() as? CKRecord ?? $0 }
        for record in saved {
            self.records[record.recordID] = record
        }
        committedSaves.append(saved)
        afterCommittedSave?(saved)
        return saved
    }
}

private final class RecordingApplyFence: HouseholdZoneRecoveryApplySessionFence, @unchecked Sendable {
    let sessionAuthority = HouseholdSessionAuthority(initiallyAuthoritative: true)
    var snapshot: HouseholdZoneRecoveryApplyAuthoritySnapshot
    var isParked = true

    init(snapshot: HouseholdZoneRecoveryApplyAuthoritySnapshot) {
        self.snapshot = snapshot
    }

    func currentAuthoritySnapshot() async throws -> HouseholdZoneRecoveryApplyAuthoritySnapshot {
        snapshot
    }

    func normalSessionIsParked() async -> Bool { isParked }
}

private struct Fixture {
    enum Shape { case single, dependency, asset }

    let sourceZone = CKRecordZone.ID(
        zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
        ownerName: CKCurrentUserDefaultName)
    let targetZone = CKRecordZone.ID(
        zoneName: "household-production",
        ownerName: CKCurrentUserDefaultName)
    let manifest: HouseholdZoneRecoveryManifest
    let plan: HouseholdZoneRecoveryApplyPlan
    let authority: HouseholdZoneRecoveryApplyAuthoritySnapshot
    let transport: RecordingApplyTransport
    let fence: RecordingApplyFence

    init(shape: Shape = .single) throws {
        let sourceScope = MirrorScope(
            accountRecordName: "account-a",
            zoneOwnerName: sourceZone.ownerName,
            zoneName: sourceZone.zoneName,
            householdID: "reserved-source",
            role: .owner,
            databaseScope: .private)
        let targetScope = MirrorScope(
            accountRecordName: "account-a",
            zoneOwnerName: targetZone.ownerName,
            zoneName: targetZone.zoneName,
            householdID: "household-a",
            role: .owner,
            databaseScope: .private)

        let inputs = try Self.inputs(shape: shape, sourceZone: sourceZone, targetZone: targetZone)
        manifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: "account-fingerprint",
            sourceScope: sourceScope,
            targetScope: targetScope,
            sourceInputFingerprint: "source-input",
            targetInputFingerprint: "target-input",
            entries: inputs.entries,
            exclusions: [])
        plan = try HouseholdZoneRecoveryApplyPlan(
            manifest: manifest,
            approval: HouseholdZoneRecoveryApproval(manifestDigest: manifest.digest()),
            sourceRecords: inputs.records,
            stagingRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("HouseholdZoneRecoveryApplierTests-\(UUID().uuidString)"))
        authority = HouseholdZoneRecoveryApplyAuthoritySnapshot(
            accountFingerprint: manifest.accountFingerprint,
            sourceScope: sourceScope,
            targetScope: targetScope,
            sessionEpoch: 7)
        transport = RecordingApplyTransport()
        fence = RecordingApplyFence(snapshot: authority)
    }

    func applier(
        manifest: HouseholdZoneRecoveryManifest? = nil,
        approval: HouseholdZoneRecoveryApproval? = nil,
        plan: HouseholdZoneRecoveryApplyPlan? = nil
    ) -> HouseholdZoneRecoveryApplier {
        let selectedManifest = manifest ?? self.manifest
        return HouseholdZoneRecoveryApplier(
            manifest: selectedManifest,
            approval: approval ?? HouseholdZoneRecoveryApproval(
                manifestDigest: try! selectedManifest.digest()),
            applyPlan: plan ?? self.plan,
            capturedAuthority: authority,
            sessionFence: fence,
            transport: transport)
    }

    func targetRecordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: targetZone)
    }

    func targetApplicationRecords() -> [CKRecord] {
        plan.approvedTargetIdentities.compactMap {
            transport.records[CKRecord.ID(recordName: $0.recordName, zoneID: targetZone)]
        }
    }

    func persistedReceipt() throws -> HouseholdZoneRecoveryReceipt? {
        let id = CKRecord.ID(
            recordName: HouseholdZoneRecoveryReceipt.recordName(manifestDigest: plan.manifestDigest),
            zoneID: targetZone)
        guard let record = transport.records[id] else { return nil }
        return try HouseholdZoneRecoveryReceipt(record: record)
    }

    private static func inputs(
        shape: Shape,
        sourceZone: CKRecordZone.ID,
        targetZone: CKRecordZone.ID
    ) throws -> (entries: [HouseholdZoneRecoveryEntry], records: [CKRecord]) {
        func identity(_ name: String, _ type: String) -> HouseholdZoneRecoveryIdentity {
            HouseholdZoneRecoveryIdentity(
                source: MirrorRecordIdentity(
                    recordType: type,
                    recordName: name,
                    zoneOwnerName: sourceZone.ownerName,
                    zoneName: sourceZone.zoneName),
                target: MirrorRecordIdentity(
                    recordType: type,
                    recordName: name,
                    zoneOwnerName: targetZone.ownerName,
                    zoneName: targetZone.zoneName))
        }
        func record(_ name: String, _ type: String) -> CKRecord {
            CKRecord(
                recordType: type,
                recordID: CKRecord.ID(recordName: name, zoneID: sourceZone))
        }

        switch shape {
        case .single:
            let recipe = record("recipe-a", "Recipe")
            recipe["name"] = "Soup" as CKRecordValue
            return ([HouseholdZoneRecoveryEntry(
                identity: identity("recipe-a", "Recipe"),
                action: .copy)], [recipe])

        case .dependency:
            let parent = record("parent", "Recipe")
            parent["name"] = "Parent" as CKRecordValue
            let child = record("child", "Recipe")
            child["name"] = "Child" as CKRecordValue
            child["baseRecipe"] = [CKRecord.Reference(
                recordID: parent.recordID,
                action: .none)] as CKRecordValue
            let parentIdentity = identity("parent", "Recipe")
            let childIdentity = identity("child", "Recipe")
            return ([
                HouseholdZoneRecoveryEntry(
                    identity: childIdentity,
                    action: .copy,
                    dependencies: [HouseholdZoneRecoveryDependency(
                        identity: parentIdentity,
                        requirement: .required)]),
                HouseholdZoneRecoveryEntry(identity: parentIdentity, action: .copy),
            ], [child, parent])

        case .asset:
            let bytes = Data("asset-lifetime".utf8)
            let sourceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("HouseholdZoneRecoverySourceAsset-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let sourceURL = sourceRoot.appendingPathComponent("image.bin")
            try bytes.write(to: sourceURL, options: .atomic)
            let recipe = record("recipe-a", "Recipe")
            recipe["name"] = "Soup" as CKRecordValue
            let image = record("rimg:recipe-a", "RecipeImage")
            image["mimeType"] = "image/png" as CKRecordValue
            image["recipe"] = CKRecord.Reference(recordID: recipe.recordID, action: .deleteSelf)
            image["imageAsset"] = CKAsset(fileURL: sourceURL)
            let recipeIdentity = identity("recipe-a", "Recipe")
            return ([
                HouseholdZoneRecoveryEntry(identity: recipeIdentity, action: .copy),
                HouseholdZoneRecoveryEntry(
                    identity: identity("rimg:recipe-a", "RecipeImage"),
                    action: .copy,
                    dependencies: [HouseholdZoneRecoveryDependency(
                        identity: recipeIdentity,
                        requirement: .required)],
                    assetDigests: ["imageAsset": ShadowMirrorDigest.sha256(bytes)]),
            ], [image, recipe])
        }
    }
}
#endif
