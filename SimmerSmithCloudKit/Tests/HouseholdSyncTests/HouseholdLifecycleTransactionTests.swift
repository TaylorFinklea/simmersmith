#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

@Suite("P2f durable household lifecycle transactions", .serialized)
struct HouseholdLifecycleTransactionTests {
    @Test("every lifecycle transaction kind survives store reconstruction")
    func roundTripAndReconstruction() throws {
        let cases: [(HouseholdLifecycleTransaction.Kind, MirrorScope?, String?)] = [
            (.accountBoundary, nil, nil),
            (.participantRevocation, participantScope(), nil),
            (.unexpectedOwnerZoneDeletion, ownerScope(), nil),
            (.factoryReset, nil, "factory-account"),
        ]

        for (kind, scope, remoteAccountRecordName) in cases {
            let directory = try lifecycleTemporaryDirectory()
            let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
            let transaction = try HouseholdLifecycleTransaction(
                kind: kind,
                scope: scope,
                remoteAccountRecordName: remoteAccountRecordName)
            let original = HouseholdLifecycleTransactionStore(fileURL: fileURL)

            try original.begin(transaction)
            #expect(try original.pending() == transaction)

            let reconstructed = HouseholdLifecycleTransactionStore(fileURL: fileURL)
            #expect(try reconstructed.pending() == transaction)
        }
    }

    @Test("successful completion durably removes the matching transaction")
    func matchingCompletionRemovesTransaction() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)

        try store.begin(transaction)
        try store.complete(transaction)

        #expect(try store.pending() == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        // Completion is intentionally idempotent for replay after a crash at the final boundary.
        try store.complete(transaction)
    }

    @Test("generic pending repairs an uncertain removal before authorizing absence")
    func absentPendingRepairsUncertainCompletion() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        let synchronizer = LifecycleDurabilitySynchronizer()
        let original = HouseholdLifecycleTransactionStore(
            fileURL: fileURL,
            pathSynchronizer: { try synchronizer.synchronize($0) })
        try original.begin(transaction)
        synchronizer.reset(failAtCall: 1)

        #expect(throws: LifecycleDurabilitySynchronizer.Failure.injected) {
            try original.complete(transaction)
        }
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(synchronizer.calls == [directory.path])

        synchronizer.reset(failAtCall: 1)
        let reconstructed = HouseholdLifecycleTransactionStore(
            fileURL: fileURL,
            pathSynchronizer: { try synchronizer.synchronize($0) })
        #expect(throws: LifecycleDurabilitySynchronizer.Failure.injected) {
            _ = try reconstructed.pending()
        }
        #expect(synchronizer.calls == [directory.path])

        synchronizer.reset()
        #expect(try reconstructed.pending() == nil)
        #expect(synchronizer.calls == [directory.path])
    }

    @Test("visible transaction retry fsyncs file and parent before authorizing replay")
    func visibleTransactionRetryReestablishesDurability() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        let synchronizer = LifecycleDurabilitySynchronizer(failAtCall: 3)
        let original = HouseholdLifecycleTransactionStore(
            fileURL: fileURL,
            pathSynchronizer: { try synchronizer.synchronize($0) })

        #expect(throws: LifecycleDurabilitySynchronizer.Failure.injected) {
            try original.begin(transaction)
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(synchronizer.calls == [directory.path, fileURL.path, directory.path])

        synchronizer.reset()
        let reconstructed = HouseholdLifecycleTransactionStore(
            fileURL: fileURL,
            pathSynchronizer: { try synchronizer.synchronize($0) })
        #expect(try reconstructed.pending() == transaction)
        #expect(synchronizer.calls == [fileURL.path, directory.path])

        synchronizer.reset()
        try reconstructed.begin(transaction)
        #expect(synchronizer.calls == [fileURL.path, directory.path])
    }

    @Test("a different pending transaction cannot be overwritten or completed")
    func pendingTransactionCannotBeReplaced() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let first = try HouseholdLifecycleTransaction(
            kind: .participantRevocation,
            scope: participantScope())
        let second = try HouseholdLifecycleTransaction(
            kind: .unexpectedOwnerZoneDeletion,
            scope: ownerScope())
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)
        try store.begin(first)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.transactionConflict) {
            try store.begin(second)
        }
        #expect(throws: HouseholdLifecycleTransactionStore.Error.transactionConflict) {
            try store.complete(second)
        }
        #expect(try store.pending() == first)
    }

    @Test("compare-and-swap replacement is durable across reconstruction")
    func matchingReplacementSurvivesReconstruction() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let exact = try HouseholdLifecycleTransaction(
            kind: .participantRevocation,
            scope: participantScope())
        let account = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)
        try store.begin(exact)

        try store.replace(expected: exact, with: account)

        #expect(try store.pending() == account)
        #expect(try HouseholdLifecycleTransactionStore(fileURL: fileURL).pending() == account)
    }

    @Test("replacement with the wrong expected transaction fails closed and preserves pending work")
    func wrongExpectedReplacementPreservesPendingTransaction() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let pending = try HouseholdLifecycleTransaction(
            kind: .participantRevocation,
            scope: participantScope())
        let wrongExpected = try HouseholdLifecycleTransaction(
            kind: .unexpectedOwnerZoneDeletion,
            scope: ownerScope())
        let replacement = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)
        try store.begin(pending)
        let originalBytes = try Data(contentsOf: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.transactionConflict) {
            try store.replace(expected: wrongExpected, with: replacement)
        }

        #expect(try Data(contentsOf: fileURL) == originalBytes)
        #expect(try store.pending() == pending)
    }

    @Test("replacement refuses malformed pending bytes without overwriting them")
    func malformedReplacementFailsClosed() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let malformed = Data("{\"formatVersion\":999}".utf8)
        try malformed.write(to: fileURL)
        let expected = try HouseholdLifecycleTransaction(
            kind: .participantRevocation,
            scope: participantScope())
        let replacement = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
            try store.replace(expected: expected, with: replacement)
        }

        #expect(try Data(contentsOf: fileURL) == malformed)
    }

    @Test("replacement refuses an absent pending transaction")
    func absentReplacementFailsClosed() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let expected = try HouseholdLifecycleTransaction(
            kind: .participantRevocation,
            scope: participantScope())
        let replacement = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.transactionConflict) {
            try store.replace(expected: expected, with: replacement)
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("malformed persisted bytes fail closed and cannot be overwritten")
    func malformedTransactionFailsClosed() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let malformed = Data("{\"formatVersion\":999}".utf8)
        try malformed.write(to: fileURL)
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
            _ = try store.pending()
        }
        #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
            try store.begin(HouseholdLifecycleTransaction(
                kind: .accountBoundary,
                scope: nil))
        }
        #expect(try Data(contentsOf: fileURL) == malformed)
    }

    @Test("decodable transaction tampering fails closed instead of targeting another scope")
    func transactionIntegrityBindsExactScope() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let transaction = try HouseholdLifecycleTransaction(
            kind: .unexpectedOwnerZoneDeletion,
            scope: ownerScope())
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)
        try store.begin(transaction)

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let tampered = original.replacingOccurrences(
            of: "account-owner",
            with: "account-other")
        #expect(tampered != original)
        try Data(tampered.utf8).write(to: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
            _ = try HouseholdLifecycleTransactionStore(fileURL: fileURL).pending()
        }
    }

    @Test("factory-reset integrity binds the creator CloudKit account")
    func factoryResetIntegrityBindsRemoteAccount() throws {
        let directory = try lifecycleTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        let store = HouseholdLifecycleTransactionStore(fileURL: fileURL)
        try store.begin(transaction)

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let tampered = original.replacingOccurrences(
            of: "factory-account",
            with: "different-account")
        #expect(tampered != original)
        try Data(tampered.utf8).write(to: fileURL)

        #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
            _ = try HouseholdLifecycleTransactionStore(fileURL: fileURL).pending()
        }
    }

    @Test("persisted factory account binding fails closed when missing empty or extraneous")
    func persistedFactoryAccountShapeIsValidated() throws {
        let factory = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        let accountBoundary = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        let factoryObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(factory)) as? [String: Any])
        let accountObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(accountBoundary))
                as? [String: Any])
        var missing = factoryObject
        missing.removeValue(forKey: "remoteAccountRecordName")
        var empty = factoryObject
        empty["remoteAccountRecordName"] = ""
        var extra = accountObject
        extra["remoteAccountRecordName"] = "unexpected-account"

        for object in [missing, empty, extra] {
            let directory = try lifecycleTemporaryDirectory()
            let fileURL = directory.appendingPathComponent("lifecycle-transaction.json")
            try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
            #expect(throws: HouseholdLifecycleTransactionStore.Error.malformedTransaction) {
                _ = try HouseholdLifecycleTransactionStore(fileURL: fileURL).pending()
            }
        }
    }

    @Test("scope requirements are validated by transaction kind")
    func scopeRequirementsAreFailClosed() throws {
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidScope) {
            _ = try HouseholdLifecycleTransaction(
                kind: .participantRevocation,
                scope: nil)
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidScope) {
            _ = try HouseholdLifecycleTransaction(
                kind: .participantRevocation,
                scope: ownerScope())
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidScope) {
            _ = try HouseholdLifecycleTransaction(
                kind: .accountBoundary,
                scope: ownerScope())
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidScope) {
            _ = try HouseholdLifecycleTransaction(
                kind: .unexpectedOwnerZoneDeletion,
                scope: participantScope())
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidScope) {
            _ = try HouseholdLifecycleTransaction(
                kind: .factoryReset,
                scope: ownerScope(),
                remoteAccountRecordName: "factory-account")
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidRemoteAccount) {
            _ = try HouseholdLifecycleTransaction(
                kind: .factoryReset,
                scope: nil)
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidRemoteAccount) {
            _ = try HouseholdLifecycleTransaction(
                kind: .factoryReset,
                scope: nil,
                remoteAccountRecordName: "   ")
        }
        #expect(throws: HouseholdLifecycleTransaction.Error.invalidRemoteAccount) {
            _ = try HouseholdLifecycleTransaction(
                kind: .accountBoundary,
                scope: nil,
                remoteAccountRecordName: "unexpected-account")
        }
    }
}

@Suite("P2f replayable shadow invalidation", .serialized)
struct HouseholdLifecycleInvalidationTests {
    @Test("exact-scope invalidation preserves every sibling scope")
    func exactScopeInvalidationPreservesSiblings() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let target = participantScope()
        let sibling = ownerScope()
        _ = try ShadowMirrorCheckpointWriter(scope: target, rootDirectory: root)
        _ = try ShadowMirrorCheckpointWriter(scope: sibling, rootDirectory: root)
        let targetSentinel = root
            .appendingPathComponent(target.cacheKey, isDirectory: true)
            .appendingPathComponent("target-data")
        let siblingSentinel = root
            .appendingPathComponent(sibling.cacheKey, isDirectory: true)
            .appendingPathComponent("sibling-data")
        try Data("target".utf8).write(to: targetSentinel)
        try Data("sibling".utf8).write(to: siblingSentinel)

        try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
            target,
            rootDirectory: root)
        try ShadowMirrorCheckpointWriter.completeScopeClearSynchronously(
            target,
            rootDirectory: root)

        #expect(!FileManager.default.fileExists(atPath: targetSentinel.path))
        #expect(FileManager.default.fileExists(atPath: siblingSentinel.path))
        _ = try ShadowMirrorCheckpointWriter(scope: sibling, rootDirectory: root)
    }

    @Test("an active generation lease defers exact clear until release and replay")
    func activeLeaseDefersExactScopeInvalidation() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = participantScope()
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        let lease = writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: [])
        let sentinel = root
            .appendingPathComponent(scope.cacheKey, isDirectory: true)
            .appendingPathComponent("leased-data")
        try Data("leased".utf8).write(to: sentinel)

        try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
            scope,
            rootDirectory: root)
        #expect(throws: MirrorCheckpointError.self) {
            try ShadowMirrorCheckpointWriter.completeScopeClearSynchronously(
                scope,
                rootDirectory: root)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))

        writer.releaseGenerationLeaseSynchronously(lease.id)
        try ShadowMirrorCheckpointWriter.completeScopeClearSynchronously(
            scope,
            rootDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    }

    @Test("a durable clear marker cannot be downgraded by leased-writer quarantine")
    func durableClearMarkerDominatesLeasedWriterQuarantine() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = participantScope()
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        let lease = writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: [])
        let sentinel = root
            .appendingPathComponent(scope.cacheKey, isDirectory: true)
            .appendingPathComponent("privacy-sensitive-data")
        try Data("must-delete".utf8).write(to: sentinel)

        try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
            scope,
            rootDirectory: root)
        let released = writer.quarantineAndReleaseGenerationLeaseSynchronously(lease.id)

        #expect(released)
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("quarantine", isDirectory: true).path))
    }

    @Test("a durable clear marker cannot be downgraded by direct writer quarantine")
    func durableClearMarkerDominatesDirectWriterQuarantine() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = participantScope()
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        let sentinel = root
            .appendingPathComponent(scope.cacheKey, isDirectory: true)
            .appendingPathComponent("privacy-sensitive-data")
        try Data("must-delete".utf8).write(to: sentinel)

        try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
            scope,
            rootDirectory: root)
        try writer.fenceAndQuarantineSynchronously()

        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("quarantine", isDirectory: true).path))
    }

    @Test("whole-root retirement supersedes a pending exact-scope process block")
    func rootRetirementSupersedesExactScopeBlock() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = participantScope()
        _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)

        try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
            scope,
            rootDirectory: root)
        try ShadowMirrorCheckpointWriter.requestRootClearSynchronously(root)
        try ShadowMirrorCheckpointWriter.completeRootClearSynchronously(root)

        _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    }

    @Test("failed exact-clear persistence preserves quarantine across a simulated restart")
    func failedClearPersistencePreservesQuarantine() async throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = ownerScope()
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        _ = try await writer.appendDelete(
            MirrorRecordIdentity(
                recordType: "Recipe",
                recordName: "pending-delete",
                zoneOwnerName: scope.zoneOwnerName,
                zoneName: scope.zoneName),
            mutationGeneration: 1)
        writer.fenceSynchronously()
        let quarantineMarker = root.appendingPathComponent(
            ".\(scope.cacheKey).deferred-quarantine")
        let clearMarker = root.appendingPathComponent(
            ".\(scope.cacheKey).deferred-clear")
        try Data("quarantine".utf8).write(to: quarantineMarker)

        #expect(throws: ShadowMirrorCheckpointWriterError.injectedFailure(
            .beforeDeferredClearMarkerWrite)
        ) {
            try ShadowMirrorCheckpointWriter.requestScopeClearSynchronously(
                scope,
                rootDirectory: root,
                failurePoint: .beforeDeferredClearMarkerWrite)
        }

        #expect(FileManager.default.fileExists(atPath: quarantineMarker.path))
        #expect(!FileManager.default.fileExists(atPath: clearMarker.path))
        ShadowMirrorCheckpointWriter.resetProcessInvalidationStateForTesting(
            rootDirectory: root)
        let reopened = ShadowMirrorBootstrapCatalog.open(
            request: .owner(accountRecordName: scope.accountRecordName),
            rootDirectory: root)
        guard case .none = reopened.outcome else {
            Issue.record("the quarantined scope became selectable after restart")
            return
        }
    }

    @Test("leased clear-marker failure leaves the prior quarantine marker intact")
    func leasedClearFailurePreservesQuarantineMarker() throws {
        let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow", isDirectory: true)
        let scope = ownerScope()
        let writer = try ShadowMirrorCheckpointWriter(
            scope: scope,
            rootDirectory: root,
            failurePoint: .beforeDeferredClearMarkerWrite)
        let lease = writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: [])
        try writer.fenceAndQuarantineSynchronously()
        let quarantineMarker = root.appendingPathComponent(
            ".\(scope.cacheKey).deferred-quarantine")
        let clearMarker = root.appendingPathComponent(
            ".\(scope.cacheKey).deferred-clear")

        #expect(throws: ShadowMirrorCheckpointWriterError.injectedFailure(
            .beforeDeferredClearMarkerWrite)
        ) {
            try writer.fenceAndClearSynchronously()
        }

        #expect(FileManager.default.fileExists(atPath: quarantineMarker.path))
        #expect(!FileManager.default.fileExists(atPath: clearMarker.path))
        writer.releaseGenerationLeaseSynchronously(lease.id)
    }

    @Test("retired cleanup removes only exact hidden retirement directories")
    func retiredDirectoryCleanupIsPrefixBounded() throws {
        let parent = try lifecycleTemporaryDirectory()
        let root = parent.appendingPathComponent("shadow", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retiredRoot = parent.appendingPathComponent(
            ".clearing-root-old", isDirectory: true)
        let retiredScope = root.appendingPathComponent(
            ".clearing-old", isDirectory: true)
        let liveScope = root.appendingPathComponent(ownerScope().cacheKey, isDirectory: true)
        let unrelatedParentHidden = parent.appendingPathComponent(
            ".clearing-root", isDirectory: true)
        let unrelatedRootHidden = root.appendingPathComponent(
            ".clearing", isDirectory: true)
        let matchingFile = root.appendingPathComponent(".clearing-not-a-directory")
        for directory in [
            retiredRoot, retiredScope, liveScope, unrelatedParentHidden, unrelatedRootHidden,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("keep".utf8).write(to: matchingFile)

        ShadowMirrorCheckpointWriter.retryRetiredDirectoryCleanupSynchronously(
            rootDirectory: root)

        #expect(!FileManager.default.fileExists(atPath: retiredRoot.path))
        #expect(!FileManager.default.fileExists(atPath: retiredScope.path))
        #expect(FileManager.default.fileExists(atPath: liveScope.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedParentHidden.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedRootHidden.path))
        #expect(FileManager.default.fileExists(atPath: matchingFile.path))
    }
}

@Suite("P2f engine lifecycle fence", .serialized)
struct HouseholdSyncLifecycleFenceTests {
    @Test("owner and participant zone deletions classify as distinct lifecycle events")
    func zoneDeletionClassification() {
        let activeZone = CKRecordZone.ID(zoneName: "household", ownerName: "owner")
        let otherZone = CKRecordZone.ID(zoneName: "other", ownerName: "owner")

        #expect(HouseholdSyncLifecyclePolicy.eventForZoneDeletion(
            ownsZone: false,
            activeZoneID: activeZone,
            deletedZoneIDs: [activeZone]) == .participantRevocation)
        #expect(HouseholdSyncLifecyclePolicy.eventForZoneDeletion(
            ownsZone: true,
            activeZoneID: activeZone,
            deletedZoneIDs: [activeZone]) == .unexpectedOwnerZoneDeletion)
        #expect(HouseholdSyncLifecyclePolicy.eventForZoneDeletion(
            ownsZone: true,
            activeZoneID: activeZone,
            deletedZoneIDs: [otherZone]) == nil)
    }

    @Test("authority and cache mutation freeze before every lifecycle callback without pre-clear")
    func freezePrecedesCallbackWithoutPreclear() throws {
        let events: [HouseholdSyncLifecycleEvent] = [
            .participantRevocation,
            .unexpectedOwnerZoneDeletion,
            .accountBoundary(.signedOut),
            .accountBoundary(.switchedAccounts),
        ]

        for event in events {
            let root = try lifecycleTemporaryDirectory().appendingPathComponent("shadow")
            let scope = event == .participantRevocation ? participantScope() : ownerScope()
            let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
            let runtime = ShadowMirrorRuntime(writer: writer)
            let authority = HouseholdSessionAuthority(initiallyAuthoritative: true)
            let fence = HouseholdSyncLifecycleFence(authority: authority)
            let store = HouseholdLocalStore()
            let record = lifecycleRecord(scope: scope)
            store.setRecord(record)
            #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 1))
            let sentinel = root
                .appendingPathComponent(scope.cacheKey, isDirectory: true)
                .appendingPathComponent("cached-data")
            try Data("cached".utf8).write(to: sentinel)
            let observation = LifecycleFenceObservation()

            fence.transition(
                to: event,
                fenceCacheMutation: {
                    observation.append("cache-fenced")
                    runtime.fence()
                },
                emit: { callbackEvent in
                    observation.append("callback")
                    observation.observe(
                        event: callbackEvent,
                        frozen: fence.isFrozen,
                        authorityDenied: authority.result(for: .save) == .notAuthoritative)
                })

            #expect(observation.order == ["cache-fenced", "callback"])
            #expect(observation.event == event)
            #expect(observation.callbackSawFrozen)
            #expect(observation.callbackSawAuthorityDenied)
            #expect(store.count() == 1)
            #expect(FileManager.default.fileExists(atPath: sentinel.path))
            #expect(!runtime.appendSaveBeforeMutation(record, mutationGeneration: 2))
        }
    }

    @Test("a lifecycle callback waits for an already-entered cache mutation to leave")
    func transitionWaitsForActiveCacheMutation() {
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: true)
        let fence = HouseholdSyncLifecycleFence(authority: authority)
        let callback = DispatchSemaphore(value: 0)
        let transitionFinished = DispatchSemaphore(value: 0)

        #expect(fence.beginActivity())
        DispatchQueue.global().async {
            fence.transition(
                to: .participantRevocation,
                fenceCacheMutation: {},
                emit: { _ in callback.signal() })
            transitionFinished.signal()
        }

        #expect(callback.wait(timeout: .now() + 0.05) == .timedOut)
        fence.endActivity()
        #expect(callback.wait(timeout: .now() + 2) == .success)
        #expect(transitionFinished.wait(timeout: .now() + 2) == .success)
    }

    @Test(
        "every explicit API rejects a lifecycle boundary crossed while suspended",
        arguments: LifecycleExplicitOperationKind.allCases)
    func boundaryCrossingExplicitOperationFailsClosed(
        kind: LifecycleExplicitOperationKind
    ) async {
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: true)
        let fence = HouseholdSyncLifecycleFence(authority: authority)
        let gate = AsyncSerialGate()
        let suspension = LifecycleOperationSuspension()
        let operation = Task {
            do {
                switch kind {
                case .fetchChanges:
                    try await HouseholdSyncExplicitOperationDriver.fetchChanges(
                        gate: gate,
                        lifecycleFence: fence,
                        operation: { await suspension.suspend() })
                case .sendChanges:
                    try await HouseholdSyncExplicitOperationDriver.sendChanges(
                        gate: gate,
                        lifecycleFence: fence,
                        operation: { await suspension.suspend() })
                case .sync:
                    try await HouseholdSyncExplicitOperationDriver.sync(
                        gate: gate,
                        lifecycleFence: fence,
                        fetch: {},
                        send: { await suspension.suspend() })
                case .sendUntilDrained:
                    try await HouseholdSyncExplicitOperationDriver.sendUntilDrained(
                        gate: gate,
                        lifecycleFence: fence,
                        maxPasses: 1,
                        pendingRecordChangeCount: { 0 },
                        send: { await suspension.suspend() })
                }
                return (rejected: false, recoveryApplyReached: true)
            } catch let result as HouseholdDataPlaneResult {
                return (
                    rejected: result == .notAuthoritative,
                    recoveryApplyReached: false)
            } catch {
                return (rejected: false, recoveryApplyReached: false)
            }
        }

        await suspension.waitUntilStarted()
        fence.transition(
            to: .accountBoundary(.switchedAccounts),
            fenceCacheMutation: {},
            emit: { _ in })
        await suspension.resume()
        let outcome = await operation.value

        #expect(outcome.rejected)
        #expect(!outcome.recoveryApplyReached)
    }
}

@Suite("P2f active mirror scope snapshot")
struct HouseholdSyncActiveMirrorScopeSnapshotTests {
    @Test("upfront normal or recovery scope stays exact and late enable is idempotent")
    func validatedScopeIsImmutable() throws {
        let snapshot = HouseholdSyncActiveMirrorScopeSnapshot()
        #expect(snapshot.value == nil)

        let participant = participantScope()
        let participantZone = CKRecordZone.ID(
            zoneName: participant.zoneName,
            ownerName: participant.zoneOwnerName)
        try snapshot.installValidated(
            participant,
            expectedZoneID: participantZone,
            ownsZone: false)
        #expect(snapshot.value == participant)
        try snapshot.installValidated(
            participant,
            expectedZoneID: participantZone,
            ownsZone: false)

        #expect(throws: MirrorCheckpointError.scopeMismatch) {
            let owner = ownerScope()
            try snapshot.installValidated(
                owner,
                expectedZoneID: CKRecordZone.ID(
                    zoneName: owner.zoneName,
                    ownerName: owner.zoneOwnerName),
                ownsZone: true)
        }
        #expect(snapshot.value == participant)
    }

    @Test("an invalid scope cannot become the lifecycle invalidation target")
    func invalidScopeIsRejected() {
        let snapshot = HouseholdSyncActiveMirrorScopeSnapshot()
        let invalid = MirrorScope(
            accountRecordName: "",
            zoneOwnerName: "owner",
            zoneName: "household",
            householdID: "household",
            role: .participant,
            databaseScope: .shared)

        #expect(throws: MirrorCheckpointError.scopeMismatch) {
            try snapshot.installValidated(
                invalid,
                expectedZoneID: CKRecordZone.ID(
                    zoneName: invalid.zoneName,
                    ownerName: invalid.zoneOwnerName),
                ownsZone: false)
        }
        #expect(snapshot.value == nil)
    }

    @Test("upfront scope rejects a zone role or database mismatch before callbacks")
    func upfrontScopeIdentityMismatchIsRejected() {
        let snapshot = HouseholdSyncActiveMirrorScopeSnapshot()
        let participant = participantScope()

        #expect(throws: MirrorCheckpointError.scopeMismatch) {
            try snapshot.installValidated(
                participant,
                expectedZoneID: CKRecordZone.ID(
                    zoneName: participant.zoneName,
                    ownerName: participant.zoneOwnerName),
                ownsZone: true)
        }
        #expect(snapshot.value == nil)
    }
}

private func lifecycleTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HouseholdLifecycleTransactionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func ownerScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-owner",
        zoneOwnerName: "owner",
        zoneName: "household-owner",
        householdID: "household-owner",
        role: .owner,
        databaseScope: .private)
}

private func participantScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-participant",
        zoneOwnerName: "owner",
        zoneName: "household-shared",
        householdID: "household-shared",
        role: .participant,
        databaseScope: .shared)
}

private func lifecycleRecord(scope: MirrorScope) -> CKRecord {
    let zoneID = CKRecordZone.ID(zoneName: scope.zoneName, ownerName: scope.zoneOwnerName)
    let record = CKRecord(
        recordType: "Recipe",
        recordID: CKRecord.ID(recordName: "recipe-lifecycle", zoneID: zoneID))
    record["name"] = "Cached recipe" as CKRecordValue
    return record
}

private final class LifecycleDurabilitySynchronizer: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case injected
    }

    private let lock = NSLock()
    private var storage: [String] = []
    private var failureCall: Int?

    init(failAtCall: Int? = nil) {
        self.failureCall = failAtCall
    }

    var calls: [String] { lock.withLock { storage } }

    func synchronize(_ url: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            storage.append(url.path)
            return storage.count == failureCall
        }
        if shouldFail { throw Failure.injected }
    }

    func reset(failAtCall: Int? = nil) {
        lock.withLock {
            storage = []
            failureCall = failAtCall
        }
    }
}

private final class LifecycleFenceObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var orderStorage: [String] = []
    private var eventStorage: HouseholdSyncLifecycleEvent?
    private var frozenStorage = false
    private var authorityDeniedStorage = false

    var order: [String] { lock.withLock { orderStorage } }
    var event: HouseholdSyncLifecycleEvent? { lock.withLock { eventStorage } }
    var callbackSawFrozen: Bool { lock.withLock { frozenStorage } }
    var callbackSawAuthorityDenied: Bool { lock.withLock { authorityDeniedStorage } }

    func append(_ entry: String) {
        lock.withLock { orderStorage.append(entry) }
    }

    func observe(
        event: HouseholdSyncLifecycleEvent,
        frozen: Bool,
        authorityDenied: Bool
    ) {
        lock.withLock {
            eventStorage = event
            frozenStorage = frozen
            authorityDeniedStorage = authorityDenied
        }
    }
}

private actor LifecycleOperationSuspension {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func resume() {
        operationContinuation?.resume()
        operationContinuation = nil
    }
}

enum LifecycleExplicitOperationKind: CaseIterable, Sendable {
    case fetchChanges
    case sendChanges
    case sync
    case sendUntilDrained
}
#endif
