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

    @Test("a layer of many independent records is chunked into deterministic, capacity-bound batches")
    func chunksLargeIndependentLayerByRecordCount() throws {
        let count = 450
        let names = (0..<count).map { String(format: "rec-%04d", $0) }
        let entries = names.map { entry($0, type: "Recipe") }
        let manifest = try makeManifest(entries: entries)
        let records = names.map { sourceRecord($0, type: "Recipe") }
        let plan = try makePlan(manifest: manifest, records: records)

        let expectedBatchCount = Int(
            ceil(Double(count) / Double(HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount)))
        #expect(plan.batches.count == expectedBatchCount)
        #expect(plan.batches.map(\.index) == Array(0..<expectedBatchCount))
        for batch in plan.batches.dropLast() {
            #expect(batch.records.count == HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount)
        }
        #expect(plan.batches.allSatisfy {
            $0.records.count <= HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount
        })
        let flattenedNames = plan.batches.flatMap { $0.records.map { $0.record.recordID.recordName } }
        #expect(Set(flattenedNames) == Set(names))
        #expect(flattenedNames.count == Set(flattenedNames).count)
    }

    @Test("a record never lands at or before the batch holding a required dependency it must follow")
    func neverPlacesDependentAtOrBeforeItsRequiredDependencyBatch() throws {
        let baseCount = HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount + 50
        let baseNames = (0..<baseCount).map { String(format: "base-%04d", $0) }
        let baseEntries = baseNames.map { entry($0, type: "Recipe") }
        let dependentEntry = entry(
            "dependent", type: "Recipe",
            dependencies: baseNames.map { dependency($0, type: "Recipe") })
        let manifest = try makeManifest(entries: baseEntries + [dependentEntry])
        let records = (baseNames + ["dependent"]).map { sourceRecord($0, type: "Recipe") }
        let plan = try makePlan(manifest: manifest, records: records)

        #expect(plan.batches.count > 2)
        let dependentBatchIndex = try #require(plan.batches.first {
            $0.records.contains { $0.record.recordID.recordName == "dependent" }
        }?.index)
        let baseBatchIndices = plan.batches.compactMap { batch -> Int? in
            batch.records.contains { baseNames.contains($0.record.recordID.recordName) }
                ? batch.index
                : nil
        }
        #expect(!baseBatchIndices.isEmpty)
        #expect(baseBatchIndices.allSatisfy { $0 < dependentBatchIndex })
    }

    @Test("a single record whose fields exceed the shared per-batch byte budget gets its own dedicated batch")
    func isolatesOversizedRecordIntoItsOwnBatch() throws {
        let oversizedEntry = entry("oversized", type: "Recipe")
        let siblingEntry = entry("sibling", type: "Recipe")
        let manifest = try makeManifest(entries: [oversizedEntry, siblingEntry])

        // Sized just under the per-record ceiling so it stays legal on its own. Two records this
        // size (~2 MB combined) still cannot share the ~2 MB per-request budget once the receipt
        // and framing overhead are subtracted, so each still lands in its own batch.
        let oversizedNotesSize = HouseholdZoneRecoveryApplyPlan.maximumRecordBytes
            - HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
            - "notes".utf8.count
            - 100
        let oversized = sourceRecord("oversized", type: "Recipe")
        oversized["notes"] = Data(count: oversizedNotesSize) as CKRecordValue
        let sibling = sourceRecord("sibling", type: "Recipe")
        sibling["notes"] = Data(count: oversizedNotesSize) as CKRecordValue

        let plan = try makePlan(manifest: manifest, records: [oversized, sibling])

        let oversizedBatch = try #require(plan.batches.first {
            $0.records.contains { $0.record.recordID.recordName == "oversized" }
        })
        #expect(oversizedBatch.records.count == 1)
        #expect(oversizedBatch.records[0].record.recordID.recordName == "oversized")
        #expect(plan.batches.count == 2)
        for batch in plan.batches {
            #expect(batch.records.count + 1 <= HouseholdZoneRecoveryApplyPlan.maximumBatchItemCount)
            for prepared in batch.records {
                #expect(HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
                    + HouseholdZoneRecoveryApplyPlan.estimatedRecordBytes(for: prepared.record)
                    <= HouseholdZoneRecoveryApplyPlan.maximumRecordBytes)
            }
        }
    }

    @Test("a record at or over the per-record byte ceiling is refused rather than emitting an over-limit record")
    func recordAtOrOverPerRecordCeilingThrows() throws {
        let manifest = try makeManifest(entries: [entry("way-too-big", type: "Recipe")])
        let record = sourceRecord("way-too-big", type: "Recipe")
        record["notes"] = Data(count: HouseholdZoneRecoveryApplyPlan.maximumRecordBytes) as CKRecordValue

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable) {
            _ = try makePlan(manifest: manifest, records: [record])
        }
    }

    @Test("the co-written receipt's bytes count against the shared batch budget: record bytes alone would fit in one batch, but the receipt forces a second")
    func receiptByteCostForcesAnAdditionalBatch() throws {
        let skipCount = 500
        let skipNames = (0..<skipCount).map { String(format: "skip-%04d", $0) }
        let skipEntries = skipNames.map { entry($0, type: "Recipe", action: .skipIdentical) }
        let skipRecords = skipNames.map { sourceRecord($0, type: "Recipe") }
        let bigAEntry = entry("big-a", type: "Recipe")
        let bigBEntry = entry("big-b", type: "Recipe")
        let manifest = try makeManifest(entries: skipEntries + [bigAEntry, bigBEntry])
        let manifestDigest = try manifest.digest()
        let identityActions = (skipEntries + [bigAEntry, bigBEntry]).map {
            HouseholdZoneRecoveryReceiptIdentityAction(
                identity: $0.identity.target, action: $0.action, decision: $0.decision)
        }.sorted { $0.identity.sortKey < $1.identity.sortKey }

        // skipIdentical entries are never batched (no CKRecord is ever written for them) but
        // they still inflate approvedIdentityActions and every per-batch application-digest
        // snapshot in the receipt, so this measures a real receipt cost record bytes alone
        // never see.
        let receiptBytesForOneBatch = try HouseholdZoneRecoveryApplyPlan.estimatedReceiptBytes(
            manifestDigest: manifestDigest,
            sourceInputFingerprint: "source-fingerprint",
            initialTargetInputFingerprint: "target-fingerprint",
            targetZoneID: targetZone,
            approvedIdentityActions: identityActions,
            batchCount: 1)
        let recordByteBudgetForOneBatch = HouseholdZoneRecoveryApplyPlan.maximumBatchRequestBytes
            - receiptBytesForOneBatch
            - HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
        let combinedFieldBytes = recordByteBudgetForOneBatch + 50_000
        let combinedClusterBytes =
            2 * HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes + combinedFieldBytes
        // Fits the raw CloudKit per-request ceiling on record bytes alone (i.e. would pass if the
        // receipt were ignored)...
        #expect(combinedClusterBytes <= HouseholdZoneRecoveryApplyPlan.maximumBatchRequestBytes)
        // ...but exceeds the real, receipt-aware budget for a single shared batch.
        #expect(combinedClusterBytes > recordByteBudgetForOneBatch)

        let perRecordNotesBytes = combinedFieldBytes / 2 - "notes".utf8.count
        let bigA = sourceRecord("big-a", type: "Recipe")
        bigA["notes"] = Data(count: perRecordNotesBytes) as CKRecordValue
        let bigB = sourceRecord("big-b", type: "Recipe")
        bigB["notes"] = Data(count: perRecordNotesBytes) as CKRecordValue

        let plan = try makePlan(manifest: manifest, records: skipRecords + [bigA, bigB])

        #expect(plan.batches.count == 2)
        let batchedNames = Set(plan.batches.flatMap { $0.records.map { $0.record.recordID.recordName } })
        #expect(batchedNames == ["big-a", "big-b"])
        for batch in plan.batches {
            #expect(batch.records.count == 1)
        }
    }

    @Test("an atomic dependency cluster too large for one request throws batchCapacityUnsatisfiable instead of emitting an over-limit batch")
    func atomicClusterExceedingCapacityThrows() throws {
        // A hub-and-spoke mutual-dependency graph (rather than a long chain) forms one strongly
        // connected component of `count` records while keeping SCC-discovery recursion depth at
        // 2 regardless of `count`, since every spoke's only dependency (the hub) is already on
        // the DFS stack when the spoke is visited.
        let count = HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount + 1
        let names = (0..<count).map { String(format: "cycle-%04d", $0) }
        let hubName = names[0]
        let spokeNames = Array(names.dropFirst())
        let hubEntry = entry(
            hubName, type: "Recipe",
            dependencies: spokeNames.map { dependency($0, type: "Recipe") })
        let spokeEntries = spokeNames.map { name in
            entry(name, type: "Recipe", dependencies: [dependency(hubName, type: "Recipe")])
        }
        let manifest = try makeManifest(entries: [hubEntry] + spokeEntries)
        let records = names.map { sourceRecord($0, type: "Recipe") }

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable) {
            _ = try makePlan(manifest: manifest, records: records)
        }
    }

    @Test("the real 657-entry, 142/515 cross-layer approved manifest shape converges on the pinned field-less batch shape and provably fits one CloudKit request")
    func realManifestShapeProducesCapacityBoundBatches() throws {
        let (manifest, records, parentCount, childCount) = try realManifestShapeManifest()
        let plan = try makePlan(manifest: manifest, records: records)

        #expect(plan.records.count == parentCount + childCount)
        #expect(plan.batches.count == 3)
        #expect(plan.batches.map(\.records.count) == [142, 399, 116])
        try assertBatchesFitOneRequest(plan)
    }

    @Test("the same real manifest shape with realistic per-record bytes converges on a byte-bound (not item-count-bound) batch shape that still provably fits one CloudKit request")
    func realManifestShapeWithRealisticBytesIsByteBound() throws {
        let (manifest, records, parentCount, childCount) = try realManifestShapeManifest(recordNotesBytes: 4_000)
        let plan = try makePlan(manifest: manifest, records: records)

        #expect(plan.records.count == parentCount + childCount)
        #expect(plan.batches.count == 3)
        #expect(plan.batches.map(\.records.count) == [142, 347, 168])
        #expect(plan.batches.allSatisfy {
            $0.records.count < HouseholdZoneRecoveryApplyPlan.maximumBatchRecordCount
        })
        try assertBatchesFitOneRequest(plan)
    }

    private func realManifestShapeManifest(recordNotesBytes: Int? = nil) throws -> (
        manifest: HouseholdZoneRecoveryManifest, records: [CKRecord], parentCount: Int, childCount: Int
    ) {
        let parentCount = 142
        let childCount = 515
        let parentNames = (0..<parentCount).map { String(format: "parent-%04d", $0) }
        let childNames = (0..<childCount).map { String(format: "child-%04d", $0) }
        let parentEntries = parentNames.map { entry($0, type: "Recipe") }
        let childEntries = childNames.enumerated().map { offset, name in
            entry(name, type: "Recipe", dependencies: [
                dependency(parentNames[offset % parentCount], type: "Recipe"),
            ])
        }
        let manifest = try makeManifest(entries: parentEntries + childEntries)
        let records = (parentNames + childNames).map { name -> CKRecord in
            let record = sourceRecord(name, type: "Recipe")
            if let recordNotesBytes {
                record["notes"] = Data(count: recordNotesBytes) as CKRecordValue
            }
            return record
        }
        return (manifest, records, parentCount, childCount)
    }

    private func assertBatchesFitOneRequest(_ plan: HouseholdZoneRecoveryApplyPlan) throws {
        for batch in plan.batches {
            #expect(batch.records.count + 1 <= HouseholdZoneRecoveryApplyPlan.maximumBatchItemCount)
            for prepared in batch.records {
                #expect(HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
                    + HouseholdZoneRecoveryApplyPlan.estimatedRecordBytes(for: prepared.record)
                    <= HouseholdZoneRecoveryApplyPlan.maximumRecordBytes)
            }
            let recordBytes = batch.records.reduce(0) {
                $0 + HouseholdZoneRecoveryApplyPlan.estimatedRecordBytes(for: $1.record)
            }
            let receiptBytes = try HouseholdZoneRecoveryApplyPlan.estimatedReceiptBytes(
                manifestDigest: plan.manifestDigest,
                sourceInputFingerprint: plan.sourceInputFingerprint,
                initialTargetInputFingerprint: plan.initialTargetInputFingerprint,
                targetZoneID: plan.targetZoneID,
                approvedIdentityActions: plan.approvedIdentityActions,
                batchCount: plan.batches.count)
            #expect(receiptBytes + HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
                <= HouseholdZoneRecoveryApplyPlan.maximumRecordBytes)
            let framing = HouseholdZoneRecoveryApplyPlan.framingAllowanceBytes(
                recordCount: batch.records.count)
            #expect(recordBytes + receiptBytes + framing
                <= HouseholdZoneRecoveryApplyPlan.maximumBatchRequestBytes)
        }
    }

    @Test("a receipt whose own bytes exhaust the per-request budget is refused before any batch is chunked")
    func receiptExhaustedBudgetThrows() throws {
        // Enough skipIdentical approved identities inflate the receipt's per-batch digest-progress
        // map (O(approvedIdentities x batchCount)) until it alone exceeds the per-request budget,
        // even though skipIdentical entries never produce a batched record. Binary search finds
        // the exact crossover count for this zone's real sortKey lengths instead of guessing one.
        let manifestDigest = "receipt-exhaustion-manifest-digest"
        func identityActions(count: Int) -> [HouseholdZoneRecoveryReceiptIdentityAction] {
            (0..<count).map { index in
                HouseholdZoneRecoveryReceiptIdentityAction(
                    identity: identity(String(format: "skip-%05d", index), type: "Recipe").target,
                    action: .skipIdentical,
                    decision: nil)
            }.sorted { $0.identity.sortKey < $1.identity.sortKey }
        }
        func fitsBudget(count: Int) throws -> Bool {
            let receiptBytes = try HouseholdZoneRecoveryApplyPlan.estimatedReceiptBytes(
                manifestDigest: manifestDigest,
                sourceInputFingerprint: "source-fingerprint",
                initialTargetInputFingerprint: "target-fingerprint",
                targetZoneID: targetZone,
                approvedIdentityActions: identityActions(count: count),
                batchCount: 1)
            return receiptBytes + HouseholdZoneRecoveryApplyPlan.perItemFramingAllowanceBytes
                <= HouseholdZoneRecoveryApplyPlan.maximumBatchRequestBytes
        }
        var low = 1
        var high = 1
        while try fitsBudget(count: high) {
            low = high
            high *= 2
        }
        while high - low > 1 {
            let mid = (low + high) / 2
            if try fitsBudget(count: mid) {
                low = mid
            } else {
                high = mid
            }
        }
        let exhaustingCount = high

        let names = (0..<exhaustingCount).map { String(format: "skip-%05d", $0) }
        let entries = names.map { entry($0, type: "Recipe", action: .skipIdentical) }
        let manifest = try makeManifest(entries: entries)
        let records = names.map { sourceRecord($0, type: "Recipe") }

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable) {
            _ = try makePlan(manifest: manifest, records: records)
        }
    }

    @Test("a batch count that cannot converge within the fixpoint's iteration bound is refused rather than looping unboundedly")
    func fixpointNonConvergenceThrows() throws {
        let count = 450
        let names = (0..<count).map { String(format: "rec-%04d", $0) }
        let entries = names.map { entry($0, type: "Recipe") }
        let manifest = try makeManifest(entries: entries)
        let manifestDigest = try manifest.digest()
        let identityActions = entries.map {
            HouseholdZoneRecoveryReceiptIdentityAction(
                identity: $0.identity.target, action: $0.action, decision: $0.decision)
        }.sorted { $0.identity.sortKey < $1.identity.sortKey }
        let preparedRecords = names.map { name in
            HouseholdZoneRecoveryPreparedRecord(
                identity: identity(name, type: "Recipe"),
                record: targetRecord(name, type: "Recipe"),
                assets: [])
        }

        // A single 450-entry layer always needs 2 batches purely from the item-count ceiling
        // (450 > maximumBatchRecordCount), so round 1 never converges on its assumed 1-batch
        // guess; capping the fixpoint at 1 iteration makes that non-convergence deterministic.
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable) {
            _ = try HouseholdZoneRecoveryApplyPlan.planChunkedBatches(
                layers: [entries],
                layerRecords: [preparedRecords],
                manifestDigest: manifestDigest,
                sourceInputFingerprint: "source-fingerprint",
                initialTargetInputFingerprint: "target-fingerprint",
                targetZoneID: targetZone,
                approvedIdentityActions: identityActions,
                maximumIterations: 1)
        }
    }


    @Test("chunked batch splitting is deterministic and preserves the final target application digest")
    func chunkingIsDeterministicAndDigestPreserving() throws {
        let count = 300
        let names = (0..<count).map { String(format: "det-%04d", $0) }
        let entries = names.map { entry($0, type: "Recipe") }
        let manifest = try makeManifest(entries: entries)
        let records = names.map { name -> CKRecord in
            let record = sourceRecord(name, type: "Recipe")
            record["name"] = name as CKRecordValue
            return record
        }

        let first = try makePlan(manifest: manifest, records: records)
        let second = try makePlan(manifest: manifest, records: records)

        #expect(first.batches.map(\.digest) == second.batches.map(\.digest))
        #expect(first.expectedFinalTargetApplicationDigest == second.expectedFinalTargetApplicationDigest)

        let allTargetRecords = first.records.map(\.record)
        let wholeSetDigest = try first.targetApplicationDigest(records: allTargetRecords)
        #expect(wholeSetDigest == first.expectedFinalTargetApplicationDigest)
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
        let targetRecords = ["keep-target", "take-source"].map {
            targetRecord($0, type: "Recipe")
        }

        let plan = try makePlan(
            manifest: manifest,
            records: records,
            targetRecords: targetRecords)

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
        #expect(receipt.sourceInputFingerprint == "source-fingerprint")
        #expect(receipt.initialTargetInputFingerprint == "target-fingerprint")
        #expect(receipt.approvedIdentityActions == plan.approvedIdentityActions)
        #expect(receipt.targetRecordApplicationDigestProgress
            == plan.targetRecordApplicationDigestProgress)
        #expect(receipt.status == .inProgress)
        #expect(receipt.completedAt == nil)
        #expect(receipt.completedBatches.isEmpty)
        #expect(receipt.expectedTargetRecordApplicationDigests.isEmpty)

        let json = try JSONEncoder().encode(receipt)
        #expect(try JSONDecoder().decode(
            HouseholdZoneRecoveryReceipt.self,
            from: json
        ) == receipt)
    }

    @Test("receipt resumes only the same digest and exact observed target state")
    func receiptResumeFencesDigestAndTargetDivergence() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(manifest: manifest, records: [sourceRecord("recipe-a", type: "Recipe")])
        let receipt = plan.initialReceipt

        let initialDigest = receipt.expectedTargetApplicationDigest
        #expect(try plan.resume(
            receipt: receipt,
            observedTargetApplicationDigest: initialDigest
        ) == receipt)

        let otherManifest = try makeManifest(
            sourceInputFingerprint: "changed-source",
            entries: [entry("recipe-a", type: "Recipe")])
        let otherPlan = try makePlan(
            manifest: otherManifest,
            records: [sourceRecord("recipe-a", type: "Recipe")])
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.differentManifestDigest) {
            _ = try otherPlan.resume(
                receipt: receipt,
                observedTargetApplicationDigest: initialDigest)
        }
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.targetDiverged) {
            _ = try plan.resume(
                receipt: receipt,
                observedTargetApplicationDigest: "changed-target-application")
        }
    }

    @Test("receipt resume refuses a divergent deterministic batch topology")
    func receiptResumeRejectsBatchTopologyDivergence() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(
            manifest: manifest,
            records: [sourceRecord("recipe-a", type: "Recipe")])
        let initialReceipt = plan.initialReceipt
        let divergentReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: plan.manifestDigest,
            sourceInputFingerprint: initialReceipt.sourceInputFingerprint,
            initialTargetInputFingerprint:
                initialReceipt.initialTargetInputFingerprint,
            targetZoneOwnerName: targetZone.ownerName,
            targetZoneName: targetZone.zoneName,
            approvedIdentityActions: initialReceipt.approvedIdentityActions,
            batchDigests: ["different-batch-digest"],
            targetApplicationDigests: [
                initialReceipt.expectedTargetApplicationDigest,
                "different-target-application-digest",
            ],
            targetRecordApplicationDigestProgress: [
                initialReceipt.targetRecordApplicationDigestProgress[0],
                initialReceipt.targetRecordApplicationDigestProgress[1],
            ])

        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchPlanDiverged) {
            _ = try plan.resume(
                receipt: divergentReceipt,
                observedTargetApplicationDigest:
                    divergentReceipt.expectedTargetApplicationDigest)
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

        let completionDate = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.incompleteReceipt) {
            _ = try receipt.markingTerminalComplete(
                observedTargetApplicationDigest:
                    receipt.expectedTargetApplicationDigest,
                completedAt: completionDate)
        }
        receipt = try receipt.recordingCompletedBatch(plan.batches[0].digest)
        #expect(receipt.completedBatchDigests == [plan.batches[0].digest])
        #expect(receipt.completedBatches == [
            HouseholdZoneRecoveryCompletedBatch(
                index: 0,
                digest: plan.batches[0].digest),
        ])
        #expect(receipt.expectedTargetRecordApplicationDigests
            == plan.targetRecordApplicationDigestProgress[1])
        #expect(try plan.resume(
            receipt: receipt,
            observedTargetApplicationDigest: receipt.expectedTargetApplicationDigest
        ) == receipt)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.batchOutOfOrder) {
            _ = try receipt.recordingCompletedBatch(plan.batches[0].digest)
        }
        receipt = try receipt.recordingCompletedBatch(plan.batches[1].digest)
        #expect(receipt.completedBatchDigests == plan.batches.map(\.digest))
        #expect(!receipt.isTerminalComplete)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.targetDiverged) {
            _ = try receipt.markingTerminalComplete(
                observedTargetApplicationDigest: "divergent-target",
                completedAt: completionDate)
        }
        receipt = try receipt.markingTerminalComplete(
            observedTargetApplicationDigest:
                receipt.expectedTargetApplicationDigest,
            completedAt: completionDate)
        #expect(receipt.isTerminalComplete)
        #expect(receipt.status == .complete)
        #expect(receipt.completedAt == completionDate)
        #expect(try plan.resume(
            receipt: receipt,
            observedTargetApplicationDigest: receipt.expectedTargetApplicationDigest
        ) == receipt)
        let persistedTerminal = receipt.makeRecord()
        #expect(persistedTerminal["status"] as? String
            == HouseholdZoneRecoveryReceiptStatus.complete.rawValue)
        #expect(persistedTerminal["completedAt"] as? Date == completionDate)
        #expect(try HouseholdZoneRecoveryReceipt(record: persistedTerminal) == receipt)
    }

    @Test("target application digest excludes receipt and system metadata but detects application divergence")
    func targetApplicationDigestHasStableBoundaries() throws {
        let source = sourceRecord("recipe-a", type: "Recipe")
        source["name"] = "Soup" as CKRecordValue
        let manifest = try makeManifest(entries: [
            entry("recipe-a", type: "Recipe", action: .skipIdentical),
        ])
        let target = targetRecord("recipe-a", type: "Recipe")
        target["name"] = "Soup" as CKRecordValue
        let plan = try makePlan(
            manifest: manifest,
            records: [source],
            targetRecords: [target])
        let receiptRecord = plan.initialReceipt.makeRecord()

        let baseline = try plan.targetApplicationDigest(records: [target])
        let withReceipt = try plan.targetApplicationDigest(
            records: [receiptRecord, target])
        let withSystemMetadata = targetRecord("recipe-a", type: "Recipe")
        withSystemMetadata["name"] = "Soup" as CKRecordValue
        withSystemMetadata.parent = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "system-parent", zoneID: targetZone),
            action: .none)
        let systemStable = try plan.targetApplicationDigest(
            records: [withSystemMetadata])

        #expect(baseline == plan.initialReceipt.expectedTargetApplicationDigest)
        #expect(withReceipt == baseline)
        #expect(systemStable == baseline)
        #expect(try plan.resume(
            receipt: plan.initialReceipt,
            observedTargetApplicationDigest: baseline
        ) == plan.initialReceipt)
        #expect(plan.expectedFinalRecordApplicationDigest(
            for: identity("recipe-a", type: "Recipe").target
        ) == plan.expectedFinalRecordApplicationDigests[
            identity("recipe-a", type: "Recipe").target.sortKey
        ])

        let divergent = targetRecord("recipe-a", type: "Recipe")
        divergent["name"] = "Changed soup" as CKRecordValue
        let divergentDigest = try plan.targetApplicationDigest(records: [divergent])
        #expect(divergentDigest != baseline)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.targetDiverged) {
            _ = try plan.resume(
                receipt: plan.initialReceipt,
                observedTargetApplicationDigest: divergentDigest)
        }
    }

    @Test("receipt Codable and CKRecord decoding reject malformed or extraneous state")
    func receiptDecodingIsStrict() throws {
        let manifest = try makeManifest(entries: [entry("recipe-a", type: "Recipe")])
        let plan = try makePlan(
            manifest: manifest,
            records: [sourceRecord("recipe-a", type: "Recipe")])
        let record = plan.initialReceipt.makeRecord()
        record["unexpected"] = "contaminated" as CKRecordValue
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidReceipt) {
            _ = try HouseholdZoneRecoveryReceipt(record: record)
        }
        let missingFingerprint = plan.initialReceipt.makeRecord()
        missingFingerprint["sourceInputFingerprint"] = nil
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidReceipt) {
            _ = try HouseholdZoneRecoveryReceipt(record: missingFingerprint)
        }

        let corruptProgress = plan.initialReceipt.makeRecord()
        corruptProgress["targetRecordApplicationDigestProgress"] =
            Data("not-json".utf8) as CKRecordValue
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidReceipt) {
            _ = try HouseholdZoneRecoveryReceipt(record: corruptProgress)
        }

        let data = try JSONEncoder().encode(plan.initialReceipt)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var extraneousObject = object
        extraneousObject["unexpected"] = "contaminated"
        let extraneous = try JSONSerialization.data(withJSONObject: extraneousObject)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidReceipt) {
            _ = try JSONDecoder().decode(
                HouseholdZoneRecoveryReceipt.self,
                from: extraneous)
        }
        object["status"] = HouseholdZoneRecoveryReceiptStatus.complete.rawValue
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: HouseholdZoneRecoveryApplyPlanError.invalidReceipt) {
            _ = try JSONDecoder().decode(
                HouseholdZoneRecoveryReceipt.self,
                from: malformed)
        }
    }


    private func makePlan(
        manifest: HouseholdZoneRecoveryManifest,
        records: some Sequence<CKRecord>,
        targetRecords: [CKRecord] = [],
        stagingRootURL: URL? = nil
    ) throws -> HouseholdZoneRecoveryApplyPlan {
        try HouseholdZoneRecoveryApplyPlan(
            manifest: manifest,
            approval: HouseholdZoneRecoveryApproval(manifestDigest: manifest.digest()),
            sourceRecords: Array(records),
            targetRecords: targetRecords,
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

    private func targetRecord(_ name: String, type: String) -> CKRecord {
        CKRecord(
            recordType: type,
            recordID: CKRecord.ID(recordName: name, zoneID: targetZone))
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
