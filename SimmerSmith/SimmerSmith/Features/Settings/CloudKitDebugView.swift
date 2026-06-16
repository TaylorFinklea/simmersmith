#if DEBUG
import SwiftUI
import SwiftData
import CloudKit
import CloudKitProvisioning
import CoexistenceSpike
import HouseholdSync
import HouseholdRecords
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
        try await engineA.fetchChanges(); try await engineA.sendUntilDrained()
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
        try await engineA.fetchChanges(); try await engineA.sendUntilDrained()
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
        try await engineA.fetchChanges(); try await engineA.sendUntilDrained()
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
#endif
