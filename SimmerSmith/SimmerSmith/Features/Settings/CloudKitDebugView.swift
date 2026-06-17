#if DEBUG
import SwiftUI
import SwiftData
import CloudKit
import CloudKitProvisioning
import CoexistenceSpike
import HouseholdSync
import HouseholdRecords
import GroceryMerge
import SimmerSmithKit

/// Debug-only panel to run the SP-A CloudKit checks on a signed-in sim/device.
/// Reachable from Settings → Developer (DEBUG builds only). Container
/// `iCloud.app.simmersmith.cloud`. See `.docs/ai/phases/cloudkit-sp-a-spec.md`.
struct CloudKitDebugView: View {
    @State private var output = "Tap a check to run it.\nThe sim/device must be signed into iCloud."
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Button("Phase 0 — HouseholdProfile round-trip") {
                    run { "round-trip name = \(try await HouseholdZoneProvisioner().verifyRoundTrip())" }
                }
                Button("Phase 0.5 — coexistence spike") {
                    runString { await CoexistenceSpike().run() }
                }
                Button("Phase 1 — private plane CRUD") {
                    runString { await runPrivatePlaneCheck() }
                }
                Button("Phase 2 — household sync engine round-trip") {
                    runString { await runHouseholdSyncCheck() }
                }
                Button("Phase 2b — typed record + cascade round-trip") {
                    runString { await runHouseholdRecordsCheck() }
                }
                Button("Phase 4 — sticky grocery field-merge") {
                    runString { await runGroceryMergeCheck() }
                }
                Button("Phase 4b — event-grocery field-merge") {
                    runString { await runEventGroceryMergeCheck() }
                }
                Button("Phase 5b — event manuallyMerged pin") {
                    runString { await runEventPinCheck() }
                }
                Button("Phase 5c — event↔week merge + unmerge") {
                    runString { await runEventWeekCheck() }
                }
                Button("Phase 5d — grocery dedupe repair") {
                    runString { await runDedupeRepairCheck() }
                }
                Button("Phase 2c — OWNER: create + publish share") {
                    runString { await runShareOwnerCheck() }
                }
                Button("Phase 2c — PARTICIPANT: accept + read share") {
                    runString { await runShareParticipantCheck() }
                }
                Button("Phase 3 — recipe image (CKAsset) round-trip") {
                    runString { await runRecipeImageCheck() }
                }
                Button("Phase 7 — migrate household round-trip") {
                    runString { await runMigrationCheck() }
                }
                Button("Phase 4 — week repair (slot/collapse/prune)") {
                    runString { await runWeekRepairCheck() }
                }
            } header: {
                SmithSectionHeader("cloudkit checks")
            } footer: {
                Text("Phase 0 proves zone + record write/read. Phase 0.5 proves NSPCKC + a CKSyncEngine-style stack coexist. Phase 1 loads the CloudKit-backed private store + checks invariants. Phase 2 drives two CKSyncEngine instances on one shared zone (= a 2nd device on this account) to prove household send/fetch/update/delete sync.")
            }

            Section {
                Text(output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                SmithSectionHeader("output")
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("CloudKit checks")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(running)
    }

    private func run(_ op: @escaping () async throws -> String) {
        running = true
        output = "Running…"
        Task {
            do { output = "✅ " + (try await op()) }
            catch { output = "❌ \(error)" }
            running = false
        }
    }

    private func runString(_ op: @escaping () async -> String) {
        running = true
        output = "Running…"
        Task {
            output = await op()
            running = false
        }
    }
}

private struct PrivatePlaneCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw PrivatePlaneCheckFailure(description: message) }
}

/// SP-A Phase 1 verification: loads the CloudKit-backed private-plane store (proving
/// NSPCKC inits against the signed-in account + entitlement + container), exercises the
/// upsert/invariant path, then deletes its own rows so re-runs stay idempotent.
/// Cross-device convergence is the manual two-device follow-up.
@MainActor
func runPrivatePlaneCheck() async -> String {
    do {
        let container = try makeSimmerSmithPrivatePlaneContainer()
        let context = container.mainContext
        let store = PrivatePlaneStore(context: context)
        var log = ["CloudKit-backed private store loaded ✅"]

        // 1. ProfileSetting — singleton per key, second write edits in place.
        try store.upsertProfileSetting(key: "unit_system", value: "us")
        try store.upsertProfileSetting(key: "unit_system", value: "metric")
        try store.save()
        let settings = try context.fetch(
            FetchDescriptor<PrivateProfileSetting>(predicate: #Predicate { $0.recordKey == "unit_system" })
        )
        try expect(settings.count == 1 && settings.first?.value == "metric",
                   "ProfileSetting dedupe/edit: expected 1 row=metric, got \(settings.map(\.value))")
        log.append("ProfileSetting upsert+edit → 1 row, value=metric ✅")

        // 2. DietaryGoal — singleton regardless of how many times written.
        try store.upsertDietaryGoal(goalType: "lose", dailyCalories: 2000, proteinG: 150,
                                    carbsG: 200, fatG: 60, fiberG: 30, notes: "first")
        try store.upsertDietaryGoal(goalType: "maintain", dailyCalories: 2200, proteinG: 160,
                                    carbsG: 220, fatG: 70, fiberG: 32, notes: "second")
        try store.save()
        let goals = try context.fetch(FetchDescriptor<PrivateDietaryGoal>())
        try expect(goals.count == 1 && goals.first?.goalType == "maintain",
                   "DietaryGoal singleton: expected 1 row=maintain, got \(goals.map(\.goalType))")
        log.append("DietaryGoal singleton → 1 row, goalType=maintain ✅")

        // 3. PreferenceSignal — deterministic key collapses duplicates.
        try store.upsertPreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 0.8, active: true)
        try store.upsertPreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 0.9, active: true)
        try store.save()
        let signals = try context.fetch(
            FetchDescriptor<PrivatePreferenceSignal>(predicate: #Predicate { $0.recordKey == "cuisine:thai" })
        )
        try expect(signals.count == 1 && signals.first?.score == 0.9,
                   "PreferenceSignal dedupe: expected 1 row score=0.9, got \(signals.map(\.score))")
        log.append("PreferenceSignal det-key dedupe → 1 row, score=0.9 ✅")

        // 4. IngredientPreference — id-keyed upsert.
        try store.upsertIngredientPreference(preferenceID: "pref-1", baseIngredientID: "ing-1",
                                             choiceMode: "preferred", rank: 1, active: true,
                                             brand: "Acme", variation: "organic")
        try store.upsertIngredientPreference(preferenceID: "pref-1", baseIngredientID: "ing-1",
                                             choiceMode: "preferred", rank: 2, active: true,
                                             brand: "Acme", variation: "organic")
        try store.save()
        let prefs = try context.fetch(
            FetchDescriptor<PrivateIngredientPreference>(predicate: #Predicate { $0.recordKey == "pref-1" })
        )
        try expect(prefs.count == 1 && prefs.first?.rank == 2,
                   "IngredientPreference upsert: expected 1 row rank=2, got \(prefs.map(\.rank))")
        log.append("IngredientPreference id-keyed upsert → 1 row, rank=2 ✅")

        // 5. Assistant transcript — messages render in createdAt order regardless of insert order.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = try store.upsertAssistantThread(threadID: "thread-1", title: "Plan this week",
                                                     createdAt: base, updatedAt: base)
        try store.upsertAssistantMessage(messageID: "m2", thread: thread, role: "assistant",
                                         content: "second", createdAt: base.addingTimeInterval(1))
        try store.upsertAssistantMessage(messageID: "m1", thread: thread, role: "user",
                                         content: "first", createdAt: base)
        try store.save()
        let ordered = try store.messages(forThreadID: "thread-1").map(\.content)
        try expect(ordered == ["first", "second"],
                   "Assistant ordering: expected [first, second], got \(ordered)")
        log.append("Assistant transcript ordering → [first, second] ✅")

        // 6. MigrationReceipt — claim-once sentinel.
        let first = try store.claimMigrationScope("phase1-check")
        let second = try store.claimMigrationScope("phase1-check")
        try expect(first && !second, "MigrationReceipt: expected claim-once (true,false), got (\(first),\(second))")
        log.append("MigrationReceipt sentinel → claim once ✅")

        // 7. Delete round-trip — remove every row this check created; thread cascade-deletes messages.
        for s in settings { context.delete(s) }
        for g in goals { context.delete(g) }
        for s in signals { context.delete(s) }
        for p in prefs { context.delete(p) }
        context.delete(thread)
        if let receipt = try context.fetch(
            FetchDescriptor<PrivateMigrationReceipt>(predicate: #Predicate { $0.recordKey == "phase1-check" })
        ).first { context.delete(receipt) }
        try store.save()
        let leftoverMessages = try store.messages(forThreadID: "thread-1").count
        try expect(leftoverMessages == 0, "Cascade delete: expected 0 messages after thread delete, got \(leftoverMessages)")
        log.append("Delete round-trip → cascade clean, store reset ✅")

        return "✅ Phase 1 private plane\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-A Phase 2a verification: drives TWO HouseholdSyncEngine instances against ONE
/// shared household zone on this account — engineB with its own local state stands in
/// for a second device. Proves the household CKSyncEngine round-trip (send → fetch →
/// update → delete) single-device. Cross-account CKShare is the manual two-account test.
func runHouseholdSyncCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-phase2-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let stateA = tmp.appendingPathComponent("hh-stateA-\(UUID().uuidString).json")
    let stateB = tmp.appendingPathComponent("hh-stateB-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateA); try? FileManager.default.removeItem(at: stateB) }

    let recordName = "hset:phase2-\(UUID().uuidString.prefix(8))"
    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: stateA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: stateB)

        // Re-fetch engineB until the record reaches the expected value (CloudKit
        // propagation between the two engines isn't instant).
        func valueInB(expected: String) async throws -> String? {
            for _ in 0...3 {
                try await engineB.fetchChanges()
                let v = storeB.record(for: recordID)?["value"] as? String
                if v == expected { return v }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: recordID)?["value"] as? String
        }

        var log = ["two CKSyncEngine instances on one shared zone ✅"]

        // 1. SEND: engineA writes a HouseholdSetting and pushes it.
        let record = CKRecord(recordType: "HouseholdSetting", recordID: recordID)
        record["key"] = "theme"
        record["value"] = "dark"
        engineA.save(record)
        try await engineA.sync()
        log.append("engineA save+send → server has hset:theme=dark ✅")

        // 2. FETCH: engineB (fresh state = a 2nd device) pulls it.
        let fetched = try await valueInB(expected: "dark")
        try expect(fetched == "dark", "engineB fetch: expected value=dark, got \(fetched ?? "nil")")
        log.append("engineB fetch → sees hset:theme=dark ✅")

        // 3. UPDATE: engineA edits the CURRENT (server-tagged) record; engineB converges.
        // Must edit storeA's copy — after the send, it carries the server change tag;
        // reusing the pre-send instance would trip serverRecordChanged.
        guard let current = storeA.record(for: recordID) else {
            throw PrivatePlaneCheckFailure(description: "engineA lost its record after send")
        }
        current["value"] = "light"
        engineA.save(current)
        try await engineA.fetchChanges()
        try await engineA.sendUntilDrained()
        let updated = try await valueInB(expected: "light")
        if updated != "light" {
            let serverValue = (try? await database.record(for: recordID))?["value"] as? String ?? "nil"
            return """
            ❌ engineB update: expected light, got \(updated ?? "nil")
            server direct-read value=\(serverValue)
            engineA trace: \(engineA.eventTrace)
            engineB trace: \(engineB.eventTrace)
            """
        }
        log.append("engineA edit → engineB converges to value=light ✅")

        // 4. DELETE: engineA deletes; engineB sees the tombstone.
        engineA.delete(recordID)
        try await engineA.sync()
        var gone = false
        for _ in 0...3 {
            try await engineB.fetchChanges()
            if storeB.record(for: recordID) == nil { gone = true; break }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        try expect(gone, "engineB delete: record still present after engineA delete")
        log.append("engineA delete → engineB record removed ✅")

        return "✅ Phase 2 household sync engine\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-A Phase 2b verification: the typed-record codec + cascade graph on the real
/// CKSyncEngine. Two engines on one shared zone (engineB = a 2nd device on this account).
/// Proves: (1) encode/decode round-trip survives Bool→INT64 + Date; (2) a CASCADE delete
/// sweeps children client-side; (3) a SET-NULL self-ref does NOT cascade.
func runHouseholdRecordsCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-phase2b-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let stateA = tmp.appendingPathComponent("hr-stateA-\(UUID().uuidString).json")
    let stateB = tmp.appendingPathComponent("hr-stateB-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateA); try? FileManager.default.removeItem(at: stateB) }
    let sfx = String(UUID().uuidString.prefix(8))

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: stateA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: stateB)

        func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func waitInB(present recordName: String, expect want: Bool) async throws -> Bool {
            for _ in 0...3 {
                try await engineB.fetchChanges()
                if (storeB.record(for: id(recordName)) != nil) == want { return true }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return (storeB.record(for: id(recordName)) != nil) == want
        }
        func saveEncoded(_ value: HouseholdRecordValue) {
            engineA.save(HouseholdRecordCodec.encode(value, zoneID: zoneID))
        }

        var log = ["typed codec on two engines / one zone ✅"]

        // 1. ENCODE/ROUND-TRIP.
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let rtName = "recipe-rt-\(sfx)"
        let recipe = HouseholdRecordValue(
            type: .recipe, recordName: rtName,
            scalars: ["name": .string("Pad Thai"), "cuisine": .string("thai"),
                      "favorite": .bool(true), "kidFriendly": .bool(false),
                      "prepMinutes": .int(20), "createdAt": .date(created)],
            refs: ["recipeTemplateID": "tmpl-9"])
        saveEncoded(recipe)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await waitInB(present: rtName, expect: true)
        guard let fetched = storeB.record(for: id(rtName)) else {
            throw PrivatePlaneCheckFailure(description: "engineB never received the Recipe")
        }
        let decoded = HouseholdRecordCodec.decode(fetched, as: .recipe)
        try expect(decoded == recipe, "round-trip mismatch: decoded \(decoded) != original")
        log.append("Recipe encode→fetch→decode equal (Bool→INT64 + Date survive) ✅")

        // 2. CASCADE: recipe + 2 .deleteSelf children → deleteCascading sweeps all 3.
        let rc = "rc-\(sfx)", ri = "ri-\(sfx)", rs = "rs-\(sfx)"
        saveEncoded(HouseholdRecordValue(type: .recipe, recordName: rc, scalars: ["name": .string("Stew")]))
        saveEncoded(HouseholdRecordValue(type: .recipeIngredient, recordName: ri,
            scalars: ["ingredientName": .string("beef"), "normalizedName": .string("beef")], refs: ["recipe": rc]))
        saveEncoded(HouseholdRecordValue(type: .recipeStep, recordName: rs,
            scalars: ["sortOrder": .int(0), "instruction": .string("simmer")], refs: ["recipe": rc]))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await waitInB(present: ri, expect: true)
        try expect(storeB.record(for: id(rc)) != nil && storeB.record(for: id(rs)) != nil,
                   "engineB missing recipe/step before cascade")
        log.append("engineB sees recipe + 2 children ✅")
        engineA.deleteCascading(id(rc))
        try await engineA.sendUntilDrained()
        let goneRecipe = try await waitInB(present: rc, expect: false)
        let goneChild = try await waitInB(present: ri, expect: false)
        try expect(goneRecipe && goneChild && storeB.record(for: id(rs)) == nil,
                   "cascade incomplete: recipe/children still present in engineB")
        log.append("deleteCascading(recipe) → engineB converges to 0 recipe + 0 children ✅")

        // 3. SET-NULL self-ref: deleting the base does NOT cascade-delete the variant.
        let base = "rb-\(sfx)", variant = "rv-\(sfx)"
        saveEncoded(HouseholdRecordValue(type: .recipe, recordName: base, scalars: ["name": .string("Base")]))
        saveEncoded(HouseholdRecordValue(type: .recipe, recordName: variant,
            scalars: ["name": .string("Variant")], refs: ["baseRecipe": base]))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await waitInB(present: variant, expect: true)
        engineA.delete(id(base))   // plain delete (SET-NULL edge must NOT sweep the variant)
        try await engineA.sendUntilDrained()
        let baseGone = try await waitInB(present: base, expect: false)
        try expect(baseGone, "base recipe not deleted")
        try expect(storeB.record(for: id(variant)) != nil,
                   "SET-NULL violated: variant was cascade-deleted with its base")
        log.append("delete(base) → variant survives (SET-NULL self-ref, no cascade) ✅")

        // Cleanup leftover from sub-test 3.
        engineA.delete(id(variant)); try? await engineA.sendUntilDrained()

        return "✅ Phase 2b typed records + cascade\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-A Phase 4 verification: the sticky grocery field-merge on the real CKSyncEngine.
/// Two engines (a 2nd device on this account), each with GrocerySyncMerger installed. Proves
/// that concurrent edits CONVERGE without blanket LWW corrupting the sticky fields — the
/// Spike-1 finding: a later auto-regen must NOT drop a peer's check/override, and a tombstone
/// must survive a concurrent regen.
func runGroceryMergeCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-phase4-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let stateA = tmp.appendingPathComponent("gm-stateA-\(UUID().uuidString).json")
    let stateB = tmp.appendingPathComponent("gm-stateB-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateA); try? FileManager.default.removeItem(at: stateB) }
    let sfx = String(UUID().uuidString.prefix(8))

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: stateA)
        engineA.merger = GrocerySyncMerger()
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: stateB)
        engineB.merger = GrocerySyncMerger()

        func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func itemInB(_ name: String) async throws -> GroceryMerge.GroceryItem? {
            for _ in 0...3 {
                try await engineB.fetchChanges()
                if let r = storeB.record(for: id(name)) { return GroceryCodec.decode(r) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: id(name)).map(GroceryCodec.decode)
        }
        // Edit a store's existing (server-tagged) record in place and save it.
        func editAndSave(_ engine: HouseholdSyncEngine, _ store: HouseholdLocalStore,
                         _ name: String, _ mutate: (inout GroceryMerge.GroceryItem) -> Void) {
            guard let rec = store.record(for: id(name)) else { return }
            var v = GroceryCodec.decode(rec)
            mutate(&v)
            GroceryCodec.encode(v, into: rec)   // preserves the server change tag
            engine.save(rec)
        }

        var log = ["two engines + GrocerySyncMerger on one zone ✅"]

        // ===== Scenario 1: later auto-regen must NOT drop a peer's check + override =====
        let g1 = "G1-\(sfx)"
        engineA.save(GroceryCodec.makeRecord(
            GroceryMerge.GroceryItem(recordName: g1, unit: "cup", normalizedName: "tomato",
                        totalQuantity: 2, sourceMeals: "meal:mon", createdAt: 1, modifiedAt: 1), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await itemInB(g1)   // engineB now holds the base row (tagged)

        // engineA regens a bigger quantity (later clock).
        editAndSave(engineA, storeA, g1) { $0.totalQuantity = 3; $0.modifiedAt = 6 }
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        // engineB, from its STALE base, checks the row + sets an override (earlier clock) → conflict → merge.
        editAndSave(engineB, storeB, g1) {
            $0.check = CheckState(isChecked: true, at: 5, by: "savanne"); $0.quantityOverride = 9; $0.modifiedAt = 5
        }
        try await engineB.sendUntilDrained()

        guard let conv = try await itemInB(g1) else { throw PrivatePlaneCheckFailure(description: "G1 missing in B") }
        try await engineA.fetchChanges()
        let convA = storeA.record(for: id(g1)).map(GroceryCodec.decode)
        try expect(conv.totalQuantity == 3 && conv.check.isChecked && conv.quantityOverride == 9,
                   "B not converged: qty=\(String(describing: conv.totalQuantity)) checked=\(conv.check.isChecked) override=\(String(describing: conv.quantityOverride))")
        try expect(convA?.totalQuantity == 3 && convA?.check.isChecked == true && convA?.quantityOverride == 9,
                   "A not converged: \(String(describing: convA))")
        log.append("regen(qty=3) + concurrent check/override → BOTH converge qty=3 + checked + override=9 ✅")
        log.append("(blanket LWW would have dropped the check — the Spike-1 corruption)")

        // ===== Scenario 2: tombstone survives a concurrent later regen =====
        let g2 = "G2-\(sfx)"
        engineA.save(GroceryCodec.makeRecord(
            GroceryMerge.GroceryItem(recordName: g2, unit: "ea", normalizedName: "salt",
                        totalQuantity: 1, createdAt: 1, modifiedAt: 1), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await itemInB(g2)

        // engineA regen (later clock) from its base; engineB removes from its stale base → conflict → merge.
        editAndSave(engineA, storeA, g2) { $0.totalQuantity = 4; $0.modifiedAt = 11 }
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        editAndSave(engineB, storeB, g2) { $0.isUserRemoved = true; $0.modifiedAt = 10 }
        try await engineB.sendUntilDrained()

        guard let tomb = try await itemInB(g2) else { throw PrivatePlaneCheckFailure(description: "G2 missing in B") }
        try await engineA.fetchChanges()
        let tombA = storeA.record(for: id(g2)).map(GroceryCodec.decode)
        try expect(tomb.isUserRemoved && tomb.totalQuantity == 4,
                   "B tombstone lost: removed=\(tomb.isUserRemoved) qty=\(String(describing: tomb.totalQuantity))")
        try expect(tombA?.isUserRemoved == true && tombA?.totalQuantity == 4, "A tombstone lost: \(String(describing: tombA))")
        log.append("regen(qty=4) + concurrent remove → BOTH converge removed=true + qty=4 (monotonic) ✅")

        // cleanup
        engineA.delete(id(g1)); engineA.delete(id(g2)); try? await engineA.sendUntilDrained()

        return "✅ Phase 4 sticky grocery field-merge\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-A Phase 5 Layer A: the multi-merger seam (DispatchingMerger) + the EventGroceryItem
/// merger, live. Proves a concurrent unmerge (nil pointer, later clock) does NOT clobber an
/// active merge pointer, and eventQuantity is preserved — across two engines on one zone.
func runEventGroceryMergeCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-phase4b-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let stateA = tmp.appendingPathComponent("eg-stateA-\(UUID().uuidString).json")
    let stateB = tmp.appendingPathComponent("eg-stateB-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateA); try? FileManager.default.removeItem(at: stateB) }
    let name = "E-\(String(UUID().uuidString.prefix(8)))"

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: stateA)
        engineA.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger()])
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: stateB)
        engineB.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger()])

        let rid = CKRecord.ID(recordName: name, zoneID: zoneID)
        func itemInB() async throws -> GroceryMerge.EventGroceryItem? {
            for _ in 0...3 {
                try await engineB.fetchChanges()
                if let r = storeB.record(for: rid) { return EventGroceryCodec.decode(r) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: rid).map(EventGroceryCodec.decode)
        }
        func editAndSave(_ engine: HouseholdSyncEngine, _ store: HouseholdLocalStore,
                         _ mutate: (inout GroceryMerge.EventGroceryItem) -> Void) {
            guard let rec = store.record(for: rid) else { return }
            var v = EventGroceryCodec.decode(rec)
            mutate(&v)
            EventGroceryCodec.encode(v, into: rec)   // preserves the server change tag
            engine.save(rec)
        }

        var log = ["DispatchingMerger(grocery + event-grocery) on two engines ✅"]

        // E0: an event contribution merged into week grocery row G.
        engineA.save(EventGroceryCodec.makeRecord(
            GroceryMerge.EventGroceryItem(recordName: name, mergedIntoGroceryItemID: "G",
                                          mergedIntoWeekID: "W", eventQuantity: 2, modifiedAt: 1), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await itemInB()

        // engineA UNMERGES (nils the pointer, later clock).
        editAndSave(engineA, storeA) { $0.mergedIntoGroceryItemID = nil; $0.mergedIntoWeekID = nil; $0.modifiedAt = 6 }
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        // engineB, from its stale base, keeps the merge live + bumps the contribution → conflict → merge.
        editAndSave(engineB, storeB) { $0.eventQuantity = 5; $0.modifiedAt = 5 }
        try await engineB.sendUntilDrained()

        guard let conv = try await itemInB() else { throw PrivatePlaneCheckFailure(description: "E missing in B") }
        try await engineA.fetchChanges()
        let convA = storeA.record(for: rid).map(EventGroceryCodec.decode)
        try expect(conv.mergedIntoGroceryItemID == "G" && conv.eventQuantity == 5,
                   "B not converged: ptr=\(String(describing: conv.mergedIntoGroceryItemID)) qty=\(String(describing: conv.eventQuantity))")
        try expect(convA?.mergedIntoGroceryItemID == "G" && convA?.eventQuantity == 5,
                   "A not converged: \(String(describing: convA))")
        log.append("unmerge(nil ptr, mod6) + concurrent keep-live(qty=5, mod5) → BOTH converge ptr=G + qty=5 ✅")
        log.append("(blanket LWW would have lost the pointer AND the contribution)")

        engineA.delete(rid); try? await engineA.sendUntilDrained()
        return "✅ Phase 4b event-grocery field-merge\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

private func phase5Engines(_ zoneName: String) -> (CKRecordZone.ID, CKDatabase, () -> DispatchingMerger) {
    let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").privateCloudDatabase
    return (zoneID, db, { DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger(), EventSyncMerger()]) })
}

/// SP-A Phase 5 Layer B: the Event manuallyMerged pin is sticky under a concurrent rename.
func runEventPinCheck() async -> String {
    let (zoneID, db, makeMerger) = phase5Engines("household-phase5b-test")
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p5b-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p5b-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let name = "EV-\(String(UUID().uuidString.prefix(8)))"
    do {
        let storeA = HouseholdLocalStore(); let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA); engineA.merger = makeMerger()
        let storeB = HouseholdLocalStore(); let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB); engineB.merger = makeMerger()
        let rid = CKRecord.ID(recordName: name, zoneID: zoneID)
        func eventInB() async throws -> CKRecord? {
            for _ in 0...3 { try await engineB.fetchChanges(); if let r = storeB.record(for: rid) { return r }; try? await Task.sleep(nanoseconds: 800_000_000) }
            return storeB.record(for: rid)
        }
        func editAndSave(_ e: HouseholdSyncEngine, _ s: HouseholdLocalStore, _ mutate: (CKRecord) -> Void) {
            guard let r = s.record(for: rid) else { return }; mutate(r); e.save(r)
        }
        var log = ["DispatchingMerger(+EventSyncMerger) on two engines ✅"]

        let rec = CKRecord(recordType: "Event", recordID: rid)
        rec["name"] = "Party"; rec["updatedAt"] = Date(timeIntervalSince1970: 1_000); rec["manuallyMerged"] = 0
        engineA.save(rec)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await eventInB()

        // A renames (later); B pins (earlier) from its stale base → conflict → merge.
        editAndSave(engineA, storeA) { $0["name"] = "Big Party"; $0["updatedAt"] = Date(timeIntervalSince1970: 2_000) }
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        editAndSave(engineB, storeB) { $0["manuallyMerged"] = 1; $0["updatedAt"] = Date(timeIntervalSince1970: 1_500) }
        try await engineB.sendUntilDrained()

        guard let conv = try await eventInB() else { throw PrivatePlaneCheckFailure(description: "event missing in B") }
        try await engineA.fetchChanges()
        let convA = storeA.record(for: rid)
        try expect((conv["name"] as? String) == "Big Party" && (conv["manuallyMerged"] as? Int) == 1,
                   "B not converged: name=\(conv["name"] as? String ?? "?") pin=\(conv["manuallyMerged"] as? Int ?? -1)")
        try expect((convA?["name"] as? String) == "Big Party" && (convA?["manuallyMerged"] as? Int) == 1,
                   "A not converged")
        log.append("rename(later) + concurrent pin(earlier) → BOTH converge name=Big Party + pin=1 ✅")
        engineA.delete(rid); try? await engineA.sendUntilDrained()
        return "✅ Phase 5b event pin\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 5 Layer F: merge an event into a week (event_quantity + event-only rows), then
/// unmerge (HARD-delete the event-only rows) — converging across two engines.
func runEventWeekCheck() async -> String {
    let (zoneID, db, makeMerger) = phase5Engines("household-phase5c-test")
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p5c-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p5c-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(6))
    let gTomato = "Gt-\(sfx)", e1 = "E1-\(sfx)", e2 = "E2-\(sfx)", ev = "EV-\(sfx)", week = "W-\(sfx)"
    do {
        let storeA = HouseholdLocalStore(); let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA); engineA.merger = makeMerger()
        let storeB = HouseholdLocalStore(); let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB); engineB.merger = makeMerger()
        let adapter = EventMergeAdapter(engine: engineA, zoneID: zoneID)
        func gid(_ n: String) -> CKRecord.ID { CKRecord.ID(recordName: n, zoneID: zoneID) }
        func syncBUntil(_ check: () -> Bool) async throws -> Bool {
            for _ in 0...4 { try await engineB.fetchChanges(); if check() { return true }; try? await Task.sleep(nanoseconds: 800_000_000) }
            return check()
        }
        func bGrocery(_ n: String) -> GroceryMerge.GroceryItem? { storeB.record(for: gid(n)).map(GroceryCodec.decode) }
        func bEventOnly() -> GroceryMerge.GroceryItem? {
            storeB.records(ofType: "GroceryItem").map(GroceryCodec.decode).first { $0.sourceMeals.hasPrefix("event:") && $0.weekID == week }
        }
        var log = ["event↔week adapter on two engines ✅"]

        // Seed: a week tomato row (meal-derived) + an Event + two event rows (1 matches, 1 doesn't).
        engineA.save(GroceryCodec.makeRecord(GroceryMerge.GroceryItem(
            recordName: gTomato, weekID: week, baseIngredientID: "b1", unit: "cup", normalizedName: "tomato",
            totalQuantity: 2, sourceMeals: "meal:mon"), zoneID: zoneID))
        let evRec = CKRecord(recordType: "Event", recordID: gid(ev)); evRec["name"] = "Party"; evRec["updatedAt"] = Date()
        engineA.save(evRec)
        engineA.save(EventGroceryCodec.makeRecord(GroceryMerge.EventGroceryItem(
            recordName: e1, eventQuantity: 3, baseIngredientID: "b1", normalizedName: "tomato", unit: "cup"), zoneID: zoneID))
        engineA.save(EventGroceryCodec.makeRecord(GroceryMerge.EventGroceryItem(
            recordName: e2, eventQuantity: 5, ingredientName: "Balloons", normalizedName: "balloons", unit: "ea"), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await syncBUntil { bGrocery(gTomato) != nil }

        // MERGE.
        let event = GroceryMerge.Event(recordName: ev, name: "Party")
        let eventRows = [GroceryMerge.EventGroceryItem(recordName: e1, eventQuantity: 3, baseIngredientID: "b1", normalizedName: "tomato", unit: "cup"),
                         GroceryMerge.EventGroceryItem(recordName: e2, eventQuantity: 5, ingredientName: "Balloons", normalizedName: "balloons", unit: "ea")]
        let merged = adapter.merge(event: event, eventRows: eventRows, intoWeek: week)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await syncBUntil { bGrocery(gTomato)?.eventQuantity == 3 && bEventOnly() != nil }
        try expect(bGrocery(gTomato)?.eventQuantity == 3, "B: tomato event_quantity not 3")
        try expect(bEventOnly()?.eventQuantity == 5, "B: event-only balloons row missing/wrong")
        log.append("merge → B sees tomato event_qty=3 + a new event-only row (balloons, qty=5) ✅")

        // UNMERGE (event now linked to the week).
        let linkedEvent = GroceryMerge.Event(recordName: ev, name: "Party", linkedWeekID: week)
        let createdName = bEventOnly()?.recordName
        let unmergeOut = adapter.unmerge(event: linkedEvent, eventRows: merged.eventRows, fromWeek: week)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await syncBUntil { bGrocery(gTomato)?.eventQuantity == nil && bEventOnly() == nil }
        if bGrocery(gTomato)?.eventQuantity != nil || bEventOnly() != nil {
            let serverTomato = (try? await db.record(for: gid(gTomato))).map(GroceryCodec.decode)
            return """
            ❌ unmerge didn't converge
            unmerge outcome: weekRows.eventQty=\(unmergeOut.weekRows.map { $0.eventQuantity }) hardDeleted=\(unmergeOut.hardDeletedRecordNames)
            A store tomato.eventQty=\(storeA.record(for: gid(gTomato)).map(GroceryCodec.decode)?.eventQuantity as Any)
            server tomato.eventQty=\(serverTomato?.eventQuantity as Any)
            B store tomato.eventQty=\(bGrocery(gTomato)?.eventQuantity as Any)
            B eventOnly present=\(bEventOnly() != nil)
            B trace tail: \(engineB.eventTrace.suffix(6))
            """
        }
        try expect(bGrocery(gTomato)?.eventQuantity == nil, "B: tomato event_quantity not cleared")
        try expect(bEventOnly() == nil, "B: event-only row not hard-deleted")
        log.append("unmerge → B: tomato event_qty cleared + event-only row HARD-deleted ✅")

        // cleanup
        engineA.delete(gid(gTomato)); engineA.delete(gid(ev)); engineA.delete(gid(e1)); engineA.delete(gid(e2))
        if let c = createdName { engineA.delete(gid(c)) }
        try? await engineA.sendUntilDrained()
        return "✅ Phase 5c event↔week merge + unmerge\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 5 Layer E: the post-batch grocery dedupe repair collapses duplicates to one
/// rolled-up keeper + a tombstone, converging across two engines, idempotently.
func runDedupeRepairCheck() async -> String {
    let (zoneID, db, makeMerger) = phase5Engines("household-phase5d-test")
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p5d-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p5d-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(6))
    let ga = "Ga-\(sfx)", gb = "Gb-\(sfx)", week = "W-\(sfx)"
    do {
        let storeA = HouseholdLocalStore(); let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA); engineA.merger = makeMerger()
        let storeB = HouseholdLocalStore(); let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB); engineB.merger = makeMerger()
        let adapter = EventMergeAdapter(engine: engineA, zoneID: zoneID)
        func gid(_ n: String) -> CKRecord.ID { CKRecord.ID(recordName: n, zoneID: zoneID) }
        func bGrocery(_ n: String) -> GroceryMerge.GroceryItem? { storeB.record(for: gid(n)).map(GroceryCodec.decode) }
        func syncBUntil(_ check: () -> Bool) async throws -> Bool {
            for _ in 0...4 { try await engineB.fetchChanges(); if check() { return true }; try? await Task.sleep(nanoseconds: 800_000_000) }
            return check()
        }
        var log = ["dedupe repair adapter on two engines ✅"]

        // Two duplicate tomato rows on the same week (different source_meals + createdAt).
        engineA.save(GroceryCodec.makeRecord(GroceryMerge.GroceryItem(
            recordName: ga, weekID: week, unit: "cup", normalizedName: "tomato", totalQuantity: 2,
            sourceMeals: "meal:mon", createdAt: 1), zoneID: zoneID))
        engineA.save(GroceryCodec.makeRecord(GroceryMerge.GroceryItem(
            recordName: gb, weekID: week, unit: "cup", normalizedName: "tomato", totalQuantity: 3,
            sourceMeals: "meal:tue", createdAt: 2), zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await syncBUntil { bGrocery(ga) != nil && bGrocery(gb) != nil }
        log.append("B sees 2 duplicate tomato rows ✅")

        // Repair on A → keeper rolls up, loser tombstoned.
        let result = adapter.dedupeWeekGrocery(weekID: week)
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        _ = try await syncBUntil { bGrocery(ga)?.totalQuantity == 5 && bGrocery(gb)?.isUserRemoved == true }
        try expect(bGrocery(ga)?.totalQuantity == 5, "B: keeper not rolled up to 5")
        try expect(bGrocery(gb)?.isUserRemoved == true, "B: loser not tombstoned")
        try expect(result.tombstoned.count == 1, "expected 1 tombstone, got \(result.tombstoned.count)")
        log.append("dedupe → keeper qty=5 + loser TOMBSTONED (not deleted), B converges ✅")

        // Idempotent re-run.
        let again = adapter.dedupeWeekGrocery(weekID: week)
        try expect(again.tombstoned.isEmpty, "re-run produced new tombstones (\(again.tombstoned.count))")
        log.append("re-run → no new tombstones, no double-count (idempotent) ✅")

        engineA.delete(gid(ga)); engineA.delete(gid(gb)); try? await engineA.sendUntilDrained()
        return "✅ Phase 5d grocery dedupe repair\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 2c OWNER side (run on one sim): create a shareable household + publish the share URL.
func runShareOwnerCheck() async -> String {
    do {
        let flow = HouseholdShareFlow()
        let result = try await flow.createAndPublishShare(householdID: "phase2c-shared", name: "Shared Household")
        return """
        ✅ Phase 2c OWNER
        owner userRecordID = \(result.ownerStamp)
        share created (publicPermission .readWrite) + URL published to the public DB ✅
        url = \(result.url.absoluteString)
        → now run PARTICIPANT on the OTHER sim (a DIFFERENT iCloud account)
        """
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 2c PARTICIPANT side (run on the OTHER sim / account): fetch + accept the share,
/// then read the owner's HouseholdProfile from the shared database. Proves cross-account sharing.
func runShareParticipantCheck() async -> String {
    do {
        let flow = HouseholdShareFlow()
        let url = try await flow.fetchPublishedURL()
        let result = try await flow.acceptAndRead(url: url)
        var log = ["fetched the published share URL + accepted the share ✅"]
        log.append("participant userRecordID = \(result.participantStamp)")
        log.append("owner userRecordID (from shared record) = \(result.ownerStamp)")
        log.append("shared household name = \(result.householdName)")
        let crossAccount = !result.ownerStamp.isEmpty && result.participantStamp != result.ownerStamp
        try expect(crossAccount,
                   "NOT cross-account: participant == owner (\(result.ownerStamp)). Both sims on the same iCloud account?")
        try expect(!result.householdName.isEmpty, "shared profile unreadable (empty name)")
        log.append("✅ GENUINE CROSS-ACCOUNT: participant ≠ owner, owner's data read via sharedCloudDatabase")
        return "✅ Phase 2c PARTICIPANT\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 3: a recipe header image stored as a CKAsset round-trips through the household
/// CKSyncEngine — engine A writes the bytes, engine B downloads + decodes the asset, bytes match.
func runRecipeImageCheck() async -> String {
    let zoneID = CKRecordZone.ID(zoneName: "household-phase3-test", ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p3-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p3-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let recipeID = "recipe-\(String(UUID().uuidString.prefix(8)))"
    let imageData = Data((0..<131072).map { UInt8($0 % 251) })   // 128 KB deterministic blob

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB)
        let rid = CKRecord.ID(recordName: RecipeImageCodec.recordName(forRecipe: recipeID), zoneID: zoneID)
        var log = ["128 KB image as CKAsset on two engines ✅"]

        let image = RecipeImage(recipeID: recipeID, mimeType: "image/png", prompt: "a test plate",
                                generatedAt: Date(timeIntervalSince1970: 1_700_000_000), imageData: imageData)
        engineA.save(try RecipeImageCodec.makeRecord(image, zoneID: zoneID))
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        log.append("engineA saved RecipeImage (\(imageData.count) bytes) + uploaded asset ✅")

        var fetched: RecipeImage?
        for _ in 0...4 {
            try await engineB.fetchChanges()
            if let r = storeB.record(for: rid) { fetched = try? RecipeImageCodec.decode(r); if fetched != nil { break } }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let got = fetched else { throw PrivatePlaneCheckFailure(description: "engineB never received/decoded the RecipeImage asset") }
        try expect(got.imageData == imageData, "asset bytes mismatch: got \(got.imageData.count) of \(imageData.count)")
        try expect(got.mimeType == "image/png" && got.prompt == "a test plate", "metadata mismatch")
        log.append("engineB downloaded the asset → \(got.imageData.count) bytes match EXACTLY + metadata intact ✅")

        engineA.delete(rid); try? await engineA.sendUntilDrained()
        return "✅ Phase 3 recipe image CKAsset\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-A Phase 7: the HouseholdMigrationRunner imports a sample household export into the zone —
/// engine B sees the migrated records; a re-run is an idempotent no-op (the MigrationReceipt gates it).
func runMigrationCheck() async -> String {
    let zoneID = CKRecordZone.ID(zoneName: "household-phase7-test", ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p7-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p7-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(6))
    let g1 = "GM1-\(sfx)", g2 = "GM2-\(sfx)", e1 = "EM1-\(sfx)", r1 = "RC1-\(sfx)", scope = "hh-\(sfx)"

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA)
        engineA.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger()])
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB)
        engineB.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger()])
        func gid(_ n: String) -> CKRecord.ID { CKRecord.ID(recordName: n, zoneID: zoneID) }
        func bHas(_ n: String) -> Bool { storeB.record(for: gid(n)) != nil }

        // A legacy household export (decoded JSON rows, snake_case) — two grocery rows + one event-grocery row.
        let export = HouseholdMigrationRunner.Export(
            groceryItems: [
                ["id": g1, "week_id": "Wmig", "normalized_name": "tomato", "unit": "cup",
                 "ingredient_name": "Tomato", "total_quantity": NSNumber(value: 2), "is_user_added": NSNumber(value: true)],
                ["id": g2, "week_id": "Wmig", "normalized_name": "salt", "unit": "tsp", "total_quantity": NSNumber(value: 1)],
                ["week_id": "Wmig"],   // no id → skipped (defensive)
            ],
            eventGroceryItems: [
                ["id": e1, "merged_into_grocery_item_id": g1, "normalized_name": "tomato",
                 "unit": "cup", "total_quantity": NSNumber(value: 3)],
            ],
            // A plain-CRUD type through the manifest-driven transform + HouseholdRecordCodec:
            // a Recipe (acronym columns, a bool, a date, an in-zone SET-NULL self-ref).
            householdRecords: [
                .recipe: [
                    ["id": r1, "name": "Lasagna", "meal_type": "dinner",
                     "source_url": "https://x.test/l", "override_payload_json": "{\"k\":1}",
                     "favorite": NSNumber(value: true), "servings": NSNumber(value: 6),
                     "created_at": "2026-06-16T20:22:00Z"],
                    ["meal_type": "lunch"],   // no id → skipped (defensive)
                ],
            ])
        let runner = HouseholdMigrationRunner(engine: engineA, zoneID: zoneID)
        var log = ["HouseholdMigrationRunner on two engines ✅"]

        let first = runner.migrate(scope: scope, export: export)
        try expect(!first.alreadyMigrated && first.groceryCount == 2 && first.eventGroceryCount == 1
                   && first.householdRecordCount == 1 && first.skippedRows == 2,
                   "first migrate: \(first)")
        log.append("migrate → 2 grocery + 1 event-grocery + 1 recipe written, 2 PK-less rows skipped ✅")
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()

        for _ in 0...4 { try await engineB.fetchChanges(); if bHas(g1) && bHas(g2) && bHas(e1) && bHas(r1) { break }; try? await Task.sleep(nanoseconds: 800_000_000) }
        try expect(bHas(g1) && bHas(g2) && bHas(e1) && bHas(r1), "engineB missing migrated records")
        let bG1 = storeB.record(for: gid(g1)).map(GroceryCodec.decode)
        try expect(bG1?.totalQuantity == 2 && bG1?.isUserAdded == true && bG1?.normalizedName == "tomato",
                   "migrated grocery fields wrong: \(String(describing: bG1))")
        let bE1 = storeB.record(for: gid(e1)).map(EventGroceryCodec.decode)
        try expect(bE1?.eventQuantity == 3 && bE1?.mergedIntoGroceryItemID == g1, "migrated event-grocery wrong")
        // The migrated Recipe decodes via the manifest codec — acronym column, bool, date all survive.
        let bR1 = storeB.record(for: gid(r1)).map { HouseholdRecordCodec.decode($0, as: .recipe) }
        try expect(bR1?.scalars["name"] == .string("Lasagna") && bR1?.scalars["mealType"] == .string("dinner")
                   && bR1?.scalars["sourceURL"] == .string("https://x.test/l")
                   && bR1?.scalars["favorite"] == .bool(true),
                   "migrated recipe fields wrong: \(String(describing: bR1?.scalars))")
        log.append("engineB sees all migrated rows w/ correct fields (grocery qty=2 user-added, event qty=3, recipe name+mealType+sourceURL+favorite) ✅")

        // Idempotency: re-run on A → the receipt short-circuits, nothing written.
        let second = runner.migrate(scope: scope, export: export)
        try expect(second.alreadyMigrated && second.groceryCount == 0, "re-run not idempotent: \(second)")
        log.append("re-run → alreadyMigrated=true, 0 writes (MigrationReceipt gate) ✅")

        for n in [g1, g2, e1, r1, HouseholdMigrationRunner.receiptRecordName(scope: scope)] { engineA.delete(gid(n)) }
        try? await engineA.sendUntilDrained()
        return "✅ Phase 7 migrate household\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

// Phase 4-remainder: the WeekRepairAdapter over real CloudKit — slot-swap, week-collapse, and
// audit-prune on engine A, then convergence on a 2nd engine. Exercises the manifest Week/WeekMeal/
// WeekChangeBatch records + the adapter's CKRecord↔value-type bridge + the engine save/delete/
// cascade wiring (the pure ConflictRepair passes are headless-tested in GroceryMergeTests).
func runWeekRepairCheck() async -> String {
    let zoneID = CKRecordZone.ID(zoneName: "household-phase4-repair", ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("p4-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("p4-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(6))
    let wA = "Wa-\(sfx)", wB = "Wb-\(sfx)"   // Wa < Wb so collapse keeps Wa
    let m1 = "M1-\(sfx)", m2 = "M2-\(sfx)", m3 = "M3-\(sfx)"
    let b0 = "B0-\(sfx)", e0 = "E0-\(sfx)"

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB)
        let adapter = WeekRepairAdapter(engine: engineA, zoneID: zoneID)
        func gid(_ n: String) -> CKRecord.ID { CKRecord.ID(recordName: n, zoneID: zoneID) }
        func save(_ type: HouseholdRecordType, _ row: [String: Any]) {
            engineA.save(HouseholdRecordCodec.encode(migrateHouseholdRecord(type, row)!, zoneID: zoneID))
        }
        func slotA(_ n: String) -> String? { storeA.record(for: gid(n))?["slot"] as? String }
        func weekRefA(_ n: String) -> String? { (storeA.record(for: gid(n))?["week"] as? CKRecord.Reference)?.recordID.recordName }
        var log: [String] = []

        // 1. slot-swap: two meals collide on (Monday, dinner).
        save(.week, ["id": wA, "week_start": "2026-06-29", "week_end": "2026-07-05"])
        save(.weekMeal, ["id": m1, "week_id": wA, "day_name": "Monday", "slot": "dinner", "sort_order": NSNumber(value: 0), "recipe_name": "A"])
        save(.weekMeal, ["id": m2, "week_id": wA, "day_name": "Monday", "slot": "dinner", "sort_order": NSNumber(value: 1), "recipe_name": "B"])
        let moved = adapter.repairSlots(weekID: wA, slots: ["breakfast", "lunch", "dinner", "snack"])
        try expect(slotA(m1) == "dinner" && slotA(m2) == "breakfast" && moved.count == 1,
                   "slot repair: m1=\(slotA(m1) ?? "?") m2=\(slotA(m2) ?? "?") moved=\(moved.count)")
        log.append("slot-swap → keeper M1 stays 'dinner', M2 moved to free 'breakfast' (1 re-saved) ✅")

        // 2. week-collapse: a duplicate week (same week_start) + a meal under it.
        save(.week, ["id": wB, "week_start": "2026-06-29", "week_end": "2026-07-05"])
        save(.weekMeal, ["id": m3, "week_id": wB, "day_name": "Tuesday", "slot": "dinner", "recipe_name": "C"])
        let collapses = try await adapter.collapseWeeks()
        try expect(collapses.count == 1 && collapses[0].keeper == wA && collapses[0].losers == [wB], "collapse: \(collapses)")
        try expect(storeA.record(for: gid(wB)) == nil && weekRefA(m3) == wA,
                   "collapse repoint: wB present=\(storeA.record(for: gid(wB)) != nil) m3.week=\(weekRefA(m3) ?? "?")")
        log.append("week-collapse → keeper Wa kept, loser Wb deleted, M3 re-parented onto Wa ✅")

        // 3. audit-prune: 4 batches (+ an event under the oldest), keep the 2 newest.
        for (i, day) in ["01", "02", "03", "04"].enumerated() {
            save(.weekChangeBatch, ["id": "B\(i)-\(sfx)", "week_id": wA, "created_at": "2026-06-\(day)T00:00:00Z", "summary": "s\(i)"])
        }
        save(.weekChangeEvent, ["id": e0, "batch_id": b0, "entity_type": "WeekMeal", "field_name": "slot"])
        let pruned = adapter.pruneAudit(weekID: wA, keep: 2)
        try expect(pruned.prune.count == 2 && pruned.keep.count == 2, "prune counts: \(pruned)")
        try expect(storeA.record(for: gid(b0)) == nil && storeA.record(for: gid(e0)) == nil,
                   "prune cascade: oldest batch + its event should be swept")
        log.append("audit-prune → 4 batches → keep 2 newest, 2 oldest + their event cascade-deleted ✅")

        // 4. it all converges on a 2nd device.
        try await engineA.sendUntilDrained(); try await engineA.fetchChanges()
        func bSlot(_ n: String) -> String? { storeB.record(for: gid(n))?["slot"] as? String }
        for _ in 0...5 {
            try await engineB.fetchChanges()
            if storeB.record(for: gid(wA)) != nil && bSlot(m2) == "breakfast" && storeB.record(for: gid(wB)) == nil { break }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        try expect(storeB.record(for: gid(wA)) != nil && storeB.record(for: gid(wB)) == nil, "engineB week state")
        try expect(bSlot(m1) == "dinner" && bSlot(m2) == "breakfast", "engineB slot state")
        try expect(storeB.record(for: gid(b0)) == nil, "engineB should not see the pruned batch")
        log.append("engineB (2nd device) converges: keeper week, distinct slots, pruned batches gone ✅")

        engineA.deleteCascading(gid(wA))   // sweeps M1/M2/M3 + the kept batches
        try? await engineA.sendUntilDrained()
        return "✅ Phase 4 week repair\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}
#endif
