#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

@Suite("HouseholdZoneRecoveryApplyPlanTests")
struct HouseholdZoneRecoveryApplyPlanTests {
    private let sourceZone = CKRecordZone.ID(
        zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
        ownerName: CKCurrentUserDefaultName)
    private let targetZone = CKRecordZone.ID(
        zoneName: "household-production",
        ownerName: CKCurrentUserDefaultName)

    @Test("reconstruction preserves identity and application values while excluding system and unknown manifest fields")
    func reconstructsApplicationFieldsOnly() throws {
        let recipe = sourceRecord("recipe-a", type: "Recipe")
        recipe["name"] = "Soup" as CKRecordValue
        recipe["servings"] = 4.5 as CKRecordValue
        recipe["createdAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
        recipe["notes"] = Data([0, 1, 2, 3]) as CKRecordValue
        recipe["tags"] = ["winter", "easy"] as CKRecordValue
        recipe["baseRecipe"] = [
            CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "recipe-a", zoneID: sourceZone),
                action: .deleteSelf),
            CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "recipe-b", zoneID: sourceZone),
                action: .none),
        ] as CKRecordValue
        recipe["notInProductionManifest"] = "exclude-me" as CKRecordValue
        recipe.parent = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "system-parent", zoneID: sourceZone), action: .none)

        let profile = sourceRecord("profile-a", type: "HouseholdProfile")
        profile["name"] = "My household" as CKRecordValue
        profile["createdAt"] = Date(timeIntervalSince1970: 99) as CKRecordValue
        profile["contaminated"] = "exclude-me" as CKRecordValue

        let manifest = try makeManifest(entries: [
            entry("recipe-a", type: "Recipe"),
            entry("profile-a", type: "HouseholdProfile"),
        ])
        let plan = try makePlan(manifest: manifest, records: [profile, recipe])
        let records = Dictionary(uniqueKeysWithValues: plan.records.map { ($0.record.recordID.recordName, $0.record) })
        let rebuiltRecipe = try #require(records["recipe-a"])
        let rebuiltProfile = try #require(records["profile-a"])

        #expect(rebuiltRecipe.recordType == "Recipe")
        #expect(rebuiltRecipe.recordID.recordName == "recipe-a")
        #expect(rebuiltRecipe.recordID.zoneID == targetZone)
        #expect(rebuiltRecipe["name"] as? String == "Soup")
        #expect(rebuiltRecipe["servings"] as? Double == 4.5)
        #expect(rebuiltRecipe["createdAt"] as? Date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(rebuiltRecipe["notes"] as? Data == Data([0, 1, 2, 3]))
        #expect(rebuiltRecipe["tags"] as? [String] == ["winter", "easy"])
        #expect(rebuiltRecipe["notInProductionManifest"] == nil)
        #expect(rebuiltRecipe.parent == nil)
        let references = try #require(rebuiltRecipe["baseRecipe"] as? [CKRecord.Reference])
        #expect(references.map(\.recordID.zoneID) == [targetZone, targetZone])
        #expect(references.map(\.recordID.recordName) == ["recipe-a", "recipe-b"])
        #expect(references.map(\.action) == [.deleteSelf, .none])

        #expect(rebuiltProfile["name"] as? String == "My household")
        #expect(rebuiltProfile["createdAt"] as? Date == Date(timeIntervalSince1970: 99))
        #expect(rebuiltProfile["contaminated"] == nil)
    }

    @Test("reconstruction refuses references outside the exact source zone and unsupported values")
    func rejectsUnsafeApplicationValues() throws {
        let foreignReference = CKRecord.Reference(
            recordID: CKRecord.ID(
                recordName: "foreign",
                zoneID: CKRecordZone.ID(zoneName: "other", ownerName: CKCurrentUserDefaultName)),
            action: .none)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.referenceOutsideSourceZone(field: "ref")) {
            _ = try HouseholdZoneRecoveryRecordReconstructor.applicationValue(
                foreignReference,
                fieldName: "ref",
                sourceZoneID: sourceZone,
                targetZoneID: targetZone)
        }
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.unsupportedApplicationValue(field: "value")) {
            _ = try HouseholdZoneRecoveryRecordReconstructor.applicationValue(
                ["nested": "dictionary"],
                fieldName: "value",
                sourceZoneID: sourceZone,
                targetZoneID: targetZone)
        }
    }

    @Test("every dedicated recovery codec copies only its production fields")
    func dedicatedCodecsUseExplicitProductionAllowlists() throws {
        let profile = sourceRecord("profile-a", type: "HouseholdProfile")
        profile["name"] = "Household" as CKRecordValue
        profile["createdAt"] = Date(timeIntervalSince1970: 1) as CKRecordValue
        profile["contaminated"] = "profile-stray" as CKRecordValue

        let grocery = sourceRecord("grocery-a", type: GroceryCodec.recordType)
        grocery["weekID"] = "week-a" as CKRecordValue
        grocery["quantityOverride"] = 2.5 as CKRecordValue
        grocery["contaminated"] = "grocery-stray" as CKRecordValue

        let eventGrocery = sourceRecord("event-grocery-a", type: EventGroceryCodec.recordType)
        eventGrocery["ingredientName"] = "Onion" as CKRecordValue
        eventGrocery["modifiedAtClock"] = 7 as CKRecordValue
        eventGrocery["contaminated"] = "event-grocery-stray" as CKRecordValue

        let recipeImage = sourceRecord("rimg:recipe-a", type: RecipeImageCodec.recordType)
        recipeImage["mimeType"] = "image/png" as CKRecordValue
        recipeImage["recipe"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "recipe-a", zoneID: sourceZone),
            action: .deleteSelf)
        recipeImage["contaminated"] = "recipe-image-stray" as CKRecordValue

        let memoryImage = sourceRecord("rmemimg:memory-a", type: RecipeMemoryImageCodec.recordType)
        memoryImage["mimeType"] = "image/jpeg" as CKRecordValue
        memoryImage["recipeMemory"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "memory-a", zoneID: sourceZone),
            action: .deleteSelf)
        memoryImage["contaminated"] = "memory-image-stray" as CKRecordValue

        let manifest = try makeManifest(entries: [
            entry("profile-a", type: "HouseholdProfile"),
            entry(
                "grocery-a",
                type: GroceryCodec.recordType,
                dependencies: [dependency("week-a", type: "Week")]),
            entry(
                "event-grocery-a",
                type: EventGroceryCodec.recordType,
                dependencies: [dependency("event-a", type: "Event")]),
            entry(
                "rimg:recipe-a",
                type: RecipeImageCodec.recordType,
                dependencies: [dependency("recipe-a", type: "Recipe")]),
            entry(
                "rmemimg:memory-a",
                type: RecipeMemoryImageCodec.recordType,
                dependencies: [dependency("memory-a", type: "RecipeMemory")]),
            entry("week-a", type: "Week"),
            entry("event-a", type: "Event"),
            entry("recipe-a", type: "Recipe"),
            entry(
                "memory-a",
                type: "RecipeMemory",
                dependencies: [dependency("recipe-a", type: "Recipe")]),
        ])
        let plan = try makePlan(
            manifest: manifest,
            records: [
                profile,
                grocery,
                eventGrocery,
                recipeImage,
                memoryImage,
                sourceRecord("week-a", type: "Week"),
                sourceRecord("event-a", type: "Event"),
                sourceRecord("recipe-a", type: "Recipe"),
                sourceRecord("memory-a", type: "RecipeMemory"),
            ])
        let rebuilt = Dictionary(uniqueKeysWithValues: plan.records.map {
            ($0.record.recordID.recordName, $0.record)
        })

        #expect(rebuilt["profile-a"]?["name"] as? String == "Household")
        #expect(rebuilt["profile-a"]?["createdAt"] as? Date == Date(timeIntervalSince1970: 1))
        #expect(rebuilt["grocery-a"]?["weekID"] as? String == "week-a")
        #expect(rebuilt["grocery-a"]?["quantityOverride"] as? Double == 2.5)
        #expect(rebuilt["event-grocery-a"]?["ingredientName"] as? String == "Onion")
        #expect(rebuilt["event-grocery-a"]?["modifiedAtClock"] as? Int64 == 7)
        #expect(rebuilt["rimg:recipe-a"]?["mimeType"] as? String == "image/png")
        #expect(rebuilt["rmemimg:memory-a"]?["mimeType"] as? String == "image/jpeg")
        for name in ["profile-a", "grocery-a", "event-grocery-a", "rimg:recipe-a", "rmemimg:memory-a"] {
            #expect(rebuilt[name]?["contaminated"] == nil)
        }
        let recipeReference = try #require(
            rebuilt["rimg:recipe-a"]?["recipe"] as? CKRecord.Reference)
        #expect(recipeReference.recordID.zoneID == targetZone)
        let memoryReference = try #require(
            rebuilt["rmemimg:memory-a"]?["recipeMemory"] as? CKRecord.Reference)
        #expect(memoryReference.recordID.zoneID == targetZone)
    }

    @Test("assets are digest-verified and restaged beneath a digest-bound durable root")
    func restagesAssetsUntilAcknowledgement() throws {
        let sourceAssetRoot = temporaryDirectory("source-assets")
        let stagingRoot = temporaryDirectory("recovery-application-support")
        let bytes = Data("verified image bytes".utf8)
        let sourceURL = sourceAssetRoot.appendingPathComponent("image.bin")
        try bytes.write(to: sourceURL, options: .atomic)
        let digest = ShadowMirrorDigest.sha256(bytes)
        let image = sourceRecord("rimg:recipe-a", type: RecipeImageCodec.recordType)
        image["mimeType"] = "image/png" as CKRecordValue
        image["generatedAt"] = Date(timeIntervalSince1970: 42) as CKRecordValue
        image["recipe"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "recipe-a", zoneID: sourceZone), action: .deleteSelf)
        image["imageAsset"] = CKAsset(fileURL: sourceURL)
        let manifest = try makeManifest(entries: [
            entry("recipe-a", type: "Recipe"),
            entry(
                "rimg:recipe-a",
                type: RecipeImageCodec.recordType,
                dependencies: [dependency("recipe-a", type: "Recipe")],
                assetDigests: ["imageAsset": digest]),
        ])

        let plan = try makePlan(
            manifest: manifest,
            records: [sourceRecord("recipe-a", type: "Recipe"), image],
            stagingRootURL: stagingRoot)
        let prepared = try #require(plan.records.first { $0.record.recordType == RecipeImageCodec.recordType })
        let staged = try #require(prepared.assets.first)
        let rebuiltAsset = try #require(prepared.record["imageAsset"] as? CKAsset)
        let rebuiltURL = try #require(rebuiltAsset.fileURL)

        #expect(staged.fieldName == "imageAsset")
        #expect(staged.sha256 == digest)
        #expect(staged.byteCount == bytes.count)
        #expect(staged.lifetime == .untilCloudKitAcknowledgement)
        #expect(staged.fileURL == rebuiltURL)
        #expect(rebuiltURL.path.hasPrefix(plan.stagingDirectoryURL.path + "/"))
        #expect(plan.stagingDirectoryURL.path.hasPrefix(stagingRoot.path + "/"))
        #expect(try Data(contentsOf: rebuiltURL) == bytes)
        #expect(FileManager.default.fileExists(atPath: rebuiltURL.path))

        let wrongManifest = try makeManifest(entries: [
            entry("rimg:recipe-a", type: RecipeImageCodec.recordType, assetDigests: ["imageAsset": "wrong"]),
        ])
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidAssetDigest(field: "imageAsset")) {
            _ = try makePlan(manifest: wrongManifest, records: [image], stagingRootURL: stagingRoot)
        }
    }

    @Test("required dependencies produce deterministic topological SCC batches")
    func plansDeterministicSCCBatches() throws {
        let parent = entry("parent", type: "Recipe")
        let child = entry(
            "child", type: "Recipe",
            dependencies: [dependency("parent", type: "Recipe")])
        let cycleA = entry(
            "cycle-a", type: "Recipe",
            dependencies: [dependency("cycle-b", type: "Recipe")])
        let cycleB = entry(
            "cycle-b", type: "Recipe",
            dependencies: [dependency("cycle-a", type: "Recipe")])
        let optional = entry(
            "optional", type: "Recipe",
            dependencies: [dependency("child", type: "Recipe", requirement: .optional)])
        let manifest = try makeManifest(entries: [child, cycleB, optional, parent, cycleA])
        let records = ["child", "cycle-b", "optional", "parent", "cycle-a"]
            .map { sourceRecord($0, type: "Recipe") }

        let first = try makePlan(manifest: manifest, records: records)
        let second = try makePlan(manifest: manifest, records: records.reversed())
        let firstNames = first.batches.map { $0.records.map { $0.record.recordID.recordName } }
        let secondNames = second.batches.map { $0.records.map { $0.record.recordID.recordName } }

        #expect(firstNames == [["cycle-a", "cycle-b", "optional", "parent"], ["child"]])
        #expect(secondNames == firstNames)
        #expect(second.batches.map(\.digest) == first.batches.map(\.digest))
        #expect(Set(firstNames[0]).isSuperset(of: ["cycle-a", "cycle-b"]))
    }

    @Test("skip-identical and target-selected conflicts are not reconstructed")
    func plansOnlySourceSelectedWrites() throws {
        let manifest = try makeManifest(entries: [
            entry("copy", type: "Recipe"),
            entry("same", type: "Recipe", action: .skipIdentical),
            entry("keep-target", type: "Recipe", action: .conflict, decision: .target),
            entry("take-source", type: "Recipe", action: .conflict, decision: .source),
        ])
        let records = ["copy", "same", "keep-target", "take-source"].map { sourceRecord($0, type: "Recipe") }

        let plan = try makePlan(manifest: manifest, records: records)

        #expect(plan.records.map { $0.record.recordID.recordName } == ["copy", "take-source"])
    }

    @Test("wrong approval preserves the typed manifest verification failure")
    func rejectsWrongApprovalWithTypedManifestError() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidManifest(.approvalMismatch)) {
            _ = try HouseholdZoneRecoveryApplyPlan(
                manifest: manifest,
                approval: HouseholdZoneRecoveryApproval(manifestDigest: "wrong-digest"),
                sourceRecords: [sourceRecord("recipe-a", type: "Recipe")])
        }
    }

    @Test("missing approved source record is refused")
    func rejectsMissingSourceRecord() throws {
        let approved = entry("recipe-a", type: "Recipe")
        let manifest = try makeManifest(entries: [approved])

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(
            approved.identity.source.sortKey
        )) {
            _ = try makePlan(manifest: manifest, records: [])
        }
    }

    @Test("duplicate source snapshots are refused")
    func rejectsDuplicateSourceRecord() throws {
        let approved = entry("recipe-a", type: "Recipe")
        let manifest = try makeManifest(entries: [approved])
        let record = sourceRecord("recipe-a", type: "Recipe")

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.duplicateSourceRecord(
            approved.identity.source.sortKey
        )) {
            _ = try makePlan(manifest: manifest, records: [record, record])
        }
    }

    @Test("source snapshot outside the exact approved source is refused")
    func rejectsMismatchedSourceRecord() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let foreign = CKRecord(
            recordType: "Recipe",
            recordID: CKRecord.ID(recordName: "recipe-a", zoneID: targetZone))
        let foreignKey = MirrorRecordIdentity(foreign).sortKey

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.sourceRecordMismatch(foreignKey)) {
            _ = try makePlan(manifest: manifest, records: [foreign])
        }
    }

    @Test("unsupported source record types are refused before reconstruction")
    func rejectsUnsupportedSourceRecordType() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.unsupportedRecordType(
            "NeverDeployedType"
        )) {
            _ = try makePlan(
                manifest: manifest,
                records: [
                    sourceRecord("recipe-a", type: "Recipe"),
                    sourceRecord("unknown-a", type: "NeverDeployedType"),
                ])
        }
    }

    @Test("receipt is versioned, target-zone bound, and round-trips through its record")
    func receiptRecordRoundTrip() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(manifest: manifest, records: [sourceRecord("recipe-a", type: "Recipe")])
        let receipt = plan.initialReceipt
        let record = receipt.makeRecord()
        let decoded = try HouseholdZoneRecoveryReceipt(record: record)

        #expect(receipt.formatVersion == HouseholdZoneRecoveryReceipt.currentFormatVersion)
        #expect(record.recordType == HouseholdZoneRecoveryReceipt.recordType)
        #expect(record.recordID.zoneID == targetZone)
        #expect(record.recordID.recordName == HouseholdZoneRecoveryReceipt.recordName(manifestDigest: plan.manifestDigest))
        #expect(decoded == receipt)
    }

    @Test("receipt resumes only the same digest and exact observed target state")
    func receiptResumeFencesDigestAndTargetDivergence() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(manifest: manifest, records: [sourceRecord("recipe-a", type: "Recipe")])
        let receipt = plan.initialReceipt

        #expect(try plan.resume(receipt: receipt, observedTargetFingerprint: "target-fingerprint") == receipt)

        let otherManifest = try makeManifest(
            sourceInputFingerprint: "changed-source",
            entries: [entry("recipe-a", type: "Recipe")])
        let otherPlan = try makePlan(
            manifest: otherManifest,
            records: [sourceRecord("recipe-a", type: "Recipe")])
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.differentManifestDigest) {
            _ = try otherPlan.resume(receipt: receipt, observedTargetFingerprint: "target-fingerprint")
        }
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.targetDiverged) {
            _ = try plan.resume(receipt: receipt, observedTargetFingerprint: "changed-target")
        }
    }

    @Test("receipt resume refuses a divergent deterministic batch topology")
    func receiptResumeRejectsBatchTopologyDivergence() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(
            manifest: manifest,
            records: [sourceRecord("recipe-a", type: "Recipe")])
        let divergentReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: plan.manifestDigest,
            targetZoneOwnerName: targetZone.ownerName,
            targetZoneName: targetZone.zoneName,
            batchDigests: ["different-batch-digest"],
            expectedTargetFingerprint: "target-fingerprint")

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchPlanDiverged) {
            _ = try plan.resume(
                receipt: divergentReceipt,
                observedTargetFingerprint: "target-fingerprint")
        }
    }

    @Test("receipt records completed batch digests in order and requires verification before terminal completion")
    func receiptProgressAndTerminalCompletion() throws {
        let parent = entry("parent", type: "Recipe")
        let child = entry(
            "child", type: "Recipe",
            dependencies: [dependency("parent", type: "Recipe")])
        let manifest = try makeManifest(entries: [child, parent])
        let plan = try makePlan(
            manifest: manifest,
            records: [sourceRecord("child", type: "Recipe"), sourceRecord("parent", type: "Recipe")])
        var receipt = plan.initialReceipt

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.incompleteReceipt) {
            _ = try receipt.markingTerminalComplete(observedTargetFingerprint: "target-fingerprint")
        }
        receipt = try receipt.recordingCompletedBatch(
            plan.batches[0].digest,
            resultingTargetFingerprint: "after-parent")
        #expect(receipt.completedBatchDigests == [plan.batches[0].digest])
        #expect(try plan.resume(receipt: receipt, observedTargetFingerprint: "after-parent") == receipt)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchOutOfOrder) {
            _ = try receipt.recordingCompletedBatch(
                plan.batches[0].digest,
                resultingTargetFingerprint: "duplicate")
        }
        receipt = try receipt.recordingCompletedBatch(
            plan.batches[1].digest,
            resultingTargetFingerprint: "after-child")
        #expect(receipt.completedBatchDigests == plan.batches.map(\.digest))
        #expect(!receipt.isTerminalComplete)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.targetDiverged) {
            _ = try receipt.markingTerminalComplete(
                observedTargetFingerprint: "divergent-target")
        }
        receipt = try receipt.markingTerminalComplete(observedTargetFingerprint: "after-child")
        #expect(receipt.isTerminalComplete)
        #expect(try plan.resume(receipt: receipt, observedTargetFingerprint: "after-child") == receipt)
    }

    private func makePlan(
        manifest: HouseholdZoneRecoveryManifest,
        records: some Sequence<CKRecord>,
        stagingRootURL: URL? = nil
    ) throws -> HouseholdZoneRecoveryApplyPlan {
        try HouseholdZoneRecoveryApplyPlan(
            manifest: manifest,
            approval: HouseholdZoneRecoveryApproval(manifestDigest: manifest.digest()),
            sourceRecords: Array(records),
            stagingRootURL: stagingRootURL)
    }

    private func makeManifest(
        sourceInputFingerprint: String = "source-fingerprint",
        targetInputFingerprint: String = "target-fingerprint",
        entries: [HouseholdZoneRecoveryEntry]
    ) throws -> HouseholdZoneRecoveryManifest {
        try HouseholdZoneRecoveryManifest(
            accountFingerprint: "account-fingerprint",
            sourceScope: scope(zoneName: sourceZone.zoneName, householdID: "reserved-source"),
            targetScope: scope(zoneName: targetZone.zoneName, householdID: "household-a"),
            sourceInputFingerprint: sourceInputFingerprint,
            targetInputFingerprint: targetInputFingerprint,
            entries: entries,
            exclusions: [])
    }

    private func scope(zoneName: String, householdID: String) -> MirrorScope {
        MirrorScope(
            accountRecordName: "account-a",
            zoneOwnerName: CKCurrentUserDefaultName,
            zoneName: zoneName,
            householdID: householdID,
            role: .owner,
            databaseScope: .private)
    }

    private func sourceRecord(_ name: String, type: String) -> CKRecord {
        CKRecord(
            recordType: type,
            recordID: CKRecord.ID(recordName: name, zoneID: sourceZone))
    }

    private func identity(_ name: String, type: String) -> HouseholdZoneRecoveryIdentity {
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

    private func entry(
        _ name: String,
        type: String,
        action: HouseholdZoneRecoveryAction = .copy,
        decision: HouseholdZoneRecoveryDecision? = nil,
        dependencies: [HouseholdZoneRecoveryDependency] = [],
        assetDigests: [String: String] = [:]
    ) -> HouseholdZoneRecoveryEntry {
        HouseholdZoneRecoveryEntry(
            identity: identity(name, type: type),
            action: action,
            decision: decision,
            dependencies: dependencies,
            assetDigests: assetDigests)
    }

    private func dependency(
        _ name: String,
        type: String,
        requirement: HouseholdZoneRecoveryDependencyRequirement = .required
    ) -> HouseholdZoneRecoveryDependency {
        HouseholdZoneRecoveryDependency(
            identity: identity(name, type: type),
            requirement: requirement)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HouseholdZoneRecoveryApplyPlanTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
