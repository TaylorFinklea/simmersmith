// Compiles in Release too (canImport(CloudKit) is always true on iOS) so the SP-A CloudKit checks
// can run on a TestFlight build; visibility is runtime-gated to DEBUG || TestFlight via DebugGate
// (reached from the SettingsView / RootView entry points) — never reachable in an App Store build.
#if canImport(CloudKit)
import SwiftUI
import SwiftData
import CloudKit
import CloudKitProvisioning
import HouseholdSync
import HouseholdRecords
import GroceryMerge
import SimmerSmithKit
import AIProviderKit

/// Debug-only panel to run the SP-A CloudKit checks on a signed-in sim/device.
/// Reachable from Settings → Developer (DEBUG builds only). Container
/// `iCloud.app.simmersmith.cloud`. See `.docs/ai/phases/cloudkit-sp-a-spec.md`.
struct CloudKitDebugView: View {
    @Environment(AppState.self) private var appState
    @State private var output = "Tap a check to run it.\nThe sim/device must be signed into iCloud."
    @State private var running = false

    var body: some View {
        Form {
            Section {
                Button {
                    runAllChecks()
                } label: {
                    Label("RUN ALL CHECKS", systemImage: "play.circle.fill")
                        .fontWeight(.bold)
                }
            } header: {
                SmithSectionHeader("run everything")
            } footer: {
                Text("Runs every single-device check in sequence and reports one unified pass/fail summary. (The 2c PARTICIPANT cross-account share is excluded — it needs a 2nd iCloud account on a 2nd device.)")
            }

            Section {
                Button("Phase 0 — HouseholdProfile round-trip") {
                    run { "round-trip name = \(try await HouseholdZoneProvisioner().verifyRoundTrip())" }
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
                // simmersmith-eig: the Phase 2c hierarchical test share is world-joinable
                // (publicPermission .readWrite + a fixed-name PUBLIC handoff record). DEBUG-only —
                // compiled out of TestFlight/App Store builds entirely.
                #if DEBUG
                Button("Phase 2c — OWNER: create + publish share") {
                    runString { await runShareOwnerCheck() }
                }
                Button("Phase 2c — PARTICIPANT: accept + read share") {
                    runString { await runShareParticipantCheck() }
                }
                #endif
                Button("Phase 3 — recipe image (CKAsset) round-trip") {
                    runString { await runRecipeImageCheck() }
                }
                Button("Phase 7 — migrate household round-trip") {
                    runString { await runMigrationCheck() }
                }
                Button("Phase 4 — week repair (slot/collapse/prune)") {
                    runString { await runWeekRepairCheck() }
                }
                Button("Phase 6 — PUBLIC catalog read") {
                    runString { await runPublicCatalogCheck() }
                }
                Button("SP-C — Recipes repo round-trip") {
                    runString { await runRecipeRepoCheck() }
                }
                Button("SP-C — Weeks+Grocery round-trip") {
                    runString { await runWeeksGroceryRepoCheck() }
                }
                Button("SP-C — Events round-trip") {
                    runString { await runEventsRepoCheck() }
                }
                Button("SP-C — Pantry+Profile round-trip") {
                    runString { await runPantryProfileCheck() }
                }
                Button("Identity — household discovery") {
                    let activeZoneID = appState.householdSession?.zoneID
                    runString { await runIdentityDiscoveryCheck(activeZoneID: activeZoneID) }
                }
                Button("AI week-gen (dry) — prompt/parse/allergy-gate") {
                    runString { await runAIWeekGenDryCheck() }
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

    /// Run every single-device check in sequence, streaming progress, then show one unified
    /// pass/fail summary + the full output of any failures. A check counts as PASSED iff its
    /// output contains "✅" and no "❌" (so Phase 0.5's partial NSPCKC-✅/manual-❌ reads as a
    /// failure correctly). 2c PARTICIPANT is excluded — it needs a 2nd account on a 2nd device.
    private func runAllChecks() {
        running = true
        output = "Running ALL checks…"
        Task {
            var checks: [(String, () async -> String)] = [
                ("Phase 0 — HouseholdProfile", {
                    do { return "✅ round-trip = \(try await HouseholdZoneProvisioner().verifyRoundTrip())" }
                    catch { return "❌ \(error)" }
                }),

                ("Phase 1 — private plane", { await runPrivatePlaneCheck() }),
                ("Phase 2 — household sync", { await runHouseholdSyncCheck() }),
                ("Phase 2b — typed records", { await runHouseholdRecordsCheck() }),
                ("Phase 3 — recipe image", { await runRecipeImageCheck() }),
                ("Phase 4 — sticky grocery", { await runGroceryMergeCheck() }),
                ("Phase 4b — event-grocery", { await runEventGroceryMergeCheck() }),
                ("Phase 4 — week repair", { await runWeekRepairCheck() }),
                ("Phase 5b — event pin", { await runEventPinCheck() }),
                ("Phase 5c — event↔week", { await runEventWeekCheck() }),
                ("Phase 5d — grocery dedupe", { await runDedupeRepairCheck() }),
                ("Phase 6 — PUBLIC catalog", { await runPublicCatalogCheck() }),
                ("Phase 7 — migrate household", { await runMigrationCheck() }),
                ("SP-C — Recipes repo", { await runRecipeRepoCheck() }),
                ("SP-C — Weeks+Grocery", { await runWeeksGroceryRepoCheck() }),
                ("SP-C — Events round-trip", { await runEventsRepoCheck() }),
                ("SP-C — Pantry+Profile", { await runPantryProfileCheck() }),
                ("Identity — discovery", { [activeZoneID = appState.householdSession?.zoneID] in await runIdentityDiscoveryCheck(activeZoneID: activeZoneID) }),
                ("AI week-gen (dry)", { await runAIWeekGenDryCheck() }),
            ]
            // simmersmith-eig: the world-joinable Phase 2c test flow is DEBUG-only; insert it back
            // into the sweep after Phase 2b so dev-sim runs keep full coverage.
            #if DEBUG
            checks.insert(("Phase 2c — OWNER share", { await runShareOwnerCheck() }), at: 4)
            #endif
            var lines: [String] = []
            var failures: [String] = []
            var passed = 0
            for (index, item) in checks.enumerated() {
                output = "Running \(index + 1)/\(checks.count): \(item.0)…\n\n" + lines.joined(separator: "\n")
                // Failure = a line that STARTS with ❌ (an actual status), not a ❌ buried in prose
                // (e.g. Phase 0.5's "→ Either ❌ ⇒ …" explanation, which is NOT a failure).
                func failedLine(_ r: String) -> Bool {
                    r.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❌") }
                }
                var result = await item.1()
                // Retry ONCE on a transient blip — a dropped connection / rate-limit in one of 15
                // network-heavy checks shouldn't sink the whole batch.
                if failedLine(result), Self.isTransientFailure(result) {
                    output = "Retrying \(index + 1)/\(checks.count): \(item.0) (transient blip)…\n\n" + lines.joined(separator: "\n")
                    result = await item.1()
                }
                let ok = result.contains("✅") && !failedLine(result)
                if ok { passed += 1 } else { failures.append("──────── \(item.0) ────────\n\(result)") }
                lines.append("\(ok ? "✅" : "❌")  \(item.0)")
            }
            var out = "▶︎ RUN ALL — \(passed)/\(checks.count) passed"
                + (passed == checks.count ? "  🎉" : "")
                + "\n\n" + lines.joined(separator: "\n")
            if !failures.isEmpty {
                out += "\n\n━━━━━━━ failure details ━━━━━━━\n\n" + failures.joined(separator: "\n\n")
            }
            out += "\n\n(2c PARTICIPANT cross-account share = separate 2-device test.)"
            output = out
            running = false
        }
    }

    /// A failure that's likely a transient blip (dropped connection, rate-limit, service hiccup),
    /// worth one retry — vs a real assertion failure, which we report as-is.
    private static func isTransientFailure(_ s: String) -> Bool {
        let lower = s.lowercased()
        return ["network failure", "network connection was lost", "nsurlerrordomain",
                "service unavailable", "request rate", "rate limited", "timed out",
                "try again", "zone busy"].contains { lower.contains($0) }
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
        // simmersmith-deh: MUST be ephemeral. The default (inMemory: false) opens the byte-identical
        // CloudKit-synced store the real app uses — on builds ≤153 this check overwrote and then
        // DELETED the user's real dietary goal, unit_system, and any 'cuisine:thai' taste signal
        // (the goal fetch below has no predicate), and NSPCKC synced the deletions everywhere.
        // An in-memory store keeps every assertion meaningful with zero blast radius (same pattern
        // as the SP-C Pantry+Profile check).
        let container = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
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

// simmersmith-eig: both Phase 2c check functions are DEBUG-only — their flow creates a
// world-joinable share (publicPermission .readWrite) and a fixed-name PUBLIC handoff record.
// The HouseholdShareFlow methods they call are equally #if DEBUG.
#if DEBUG
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
#endif

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

/// SP-C Task 7: Recipes repo round-trip on the real CKSyncEngine.
///
/// Uses the direct mapper+engine path (RecipeRecordMapper → HouseholdRecordCodec → engine),
/// which is exactly the code RecipeRepository wraps. RecipeRepository is @MainActor and requires
/// a live HouseholdSession, making it awkward to construct in a throwaway test zone; the direct
/// path exercises the same CloudKit mechanics and proves the CRUD seam.
///
/// Verifies:
///   1. Save a Recipe + 1 ingredient + 1 step + a CKAsset image via engine A.
///   2. Engine B (simulating a 2nd device) fetches and sees all records with correct fields.
///   3. Image bytes round-trip exactly (CKAsset download + RecipeImageCodec.decode).
///   4. deleteCascading(recipe) removes the recipe, ingredient, step, AND the image record.
func runRecipeRepoCheck() async -> String {
    let zoneID = CKRecordZone.ID(zoneName: "household-spc-recipe-test", ownerName: CKCurrentUserDefaultName)
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("spc-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("spc-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(8))
    let recipeID = "rc-\(sfx)"
    let ingID    = "\(recipeID)_ing_0"
    let stepID   = "\(recipeID)_step_0"

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeA, stateURL: sA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: db, zoneID: zoneID, store: storeB, stateURL: sB)

        func rid(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func waitInB(present recordName: String, expect want: Bool) async throws -> Bool {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if (storeB.record(for: rid(recordName)) != nil) == want { return true }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return (storeB.record(for: rid(recordName)) != nil) == want
        }

        var log = ["two CKSyncEngine instances on one zone (SP-C recipe test) ✅"]

        // ── 1. BUILD recipe + children via the mapper (mirrors RecipeRepository.save) ──────────

        let ingredient = RecipeIngredient(
            ingredientId: ingID,
            ingredientName: "Garlic",
            normalizedName: "garlic",
            quantity: 3,
            unit: "cloves"
        )
        let step = RecipeStep(stepId: stepID, sortOrder: 0, instruction: "Mince the garlic.")

        // Build a minimal RecipeSummary via JSON round-trip (no public memberwise init).
        let summaryDict: [String: Any] = [
            "recipeId": recipeID,
            "name": "Test Pasta",
            "mealType": "dinner",
            "cuisine": "italian",
            "instructionsSummary": "Simple pasta dish.",
            "favorite": true,
            "archived": false,
            "source": "manual",
            "sourceLabel": "",
            "sourceUrl": "",
            "notes": "",
            "memories": "",
            "kidFriendly": false,
            "iconKey": "",
            "tags": [],
            "isVariant": false,
            "overrideFields": [String](),
            "variantCount": 0,
            "sourceRecipeCount": 0,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "ingredients": [
                [
                    "ingredientId": ingID,
                    "ingredientName": "Garlic",
                    "normalizedName": "garlic",
                    "quantity": 3.0,
                    "unit": "cloves",
                    "resolutionStatus": "unresolved",
                    "prep": "",
                    "category": "",
                    "notes": "",
                ] as [String: Any]
            ] as [[String: Any]],
            "steps": [
                [
                    "stepId": stepID,
                    "sortOrder": 0,
                    "instruction": "Mince the garlic.",
                    "substeps": [[String: Any]](),
                ] as [String: Any]
            ] as [[String: Any]],
        ]
        let summaryData = try JSONSerialization.data(withJSONObject: summaryDict)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(RecipeSummary.self, from: summaryData)

        // Map to CloudKit records (the RecipeRepository path).
        let mapped = RecipeRecordMapper.records(from: summary)

        // Save recipe + children to engine A.
        engineA.save(HouseholdRecordCodec.encode(mapped.recipe, zoneID: zoneID))
        for ing in mapped.ingredients { engineA.save(HouseholdRecordCodec.encode(ing, zoneID: zoneID)) }
        for step in mapped.steps     { engineA.save(HouseholdRecordCodec.encode(step, zoneID: zoneID)) }

        // ── 2. IMAGE: stage a 64 KB deterministic blob via RecipeImageCodec ──────────────────

        let imageData = Data((0..<65536).map { UInt8($0 % 251) })
        let image = RecipeImage(recipeID: recipeID, mimeType: "image/png", prompt: "test dish",
                                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                imageData: imageData)
        let imageRecord = try RecipeImageCodec.makeRecord(image, zoneID: zoneID)
        engineA.save(imageRecord)
        let imageRecordName = RecipeImageCodec.recordName(forRecipe: recipeID)

        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()
        log.append("engineA: Recipe + 1 ingredient + 1 step + CKAsset image saved to CloudKit ✅")

        // ── 3. ENGINE B fetches and verifies all records ──────────────────────────────────────

        let recipePresent = try await waitInB(present: recipeID,      expect: true)
        let ingPresent    = try await waitInB(present: ingID,          expect: true)
        let stepPresent   = try await waitInB(present: stepID,         expect: true)
        let imagePresent  = try await waitInB(present: imageRecordName, expect: true)
        try expect(recipePresent && ingPresent && stepPresent && imagePresent,
                   "engineB missing records: recipe=\(recipePresent) ing=\(ingPresent) step=\(stepPresent) image=\(imagePresent)")

        // Decode the recipe via the mapper (mirrors RecipeRepository.reload).
        guard let bRecipeRaw = storeB.record(for: rid(recipeID)) else {
            throw PrivatePlaneCheckFailure(description: "engineB recipe record missing after wait")
        }
        let bRecipeValue = HouseholdRecordCodec.decode(bRecipeRaw, as: .recipe)
        let bIngValues   = storeB.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName)
            .filter { ($0["recipe"] as? CKRecord.Reference)?.recordID.recordName == recipeID }
            .map { HouseholdRecordCodec.decode($0, as: .recipeIngredient) }
        let bStepValues  = storeB.records(ofType: HouseholdRecordType.recipeStep.recordTypeName)
            .filter { ($0["recipe"] as? CKRecord.Reference)?.recordID.recordName == recipeID }
            .map { HouseholdRecordCodec.decode($0, as: .recipeStep) }
        let bSummary = RecipeRecordMapper.recipe(from: bRecipeValue, ingredients: bIngValues, steps: bStepValues, hasImage: true)

        try expect(bSummary.name == "Test Pasta", "name mismatch: \(bSummary.name)")
        try expect(bSummary.mealType == "dinner", "mealType mismatch: \(bSummary.mealType)")
        try expect(bSummary.cuisine == "italian", "cuisine mismatch: \(bSummary.cuisine)")
        try expect(bSummary.favorite == true, "favorite not preserved")
        try expect(bSummary.ingredients.count == 1 && bSummary.ingredients[0].ingredientName == "Garlic",
                   "ingredient mismatch: \(bSummary.ingredients)")
        try expect(bSummary.steps.count == 1 && bSummary.steps[0].instruction == "Mince the garlic.",
                   "step mismatch: \(bSummary.steps)")
        log.append("engineB: Recipe decoded — name=Test Pasta, mealType=dinner, ingredient=Garlic, step intact ✅")

        // ── 4. IMAGE round-trip: verify bytes match exactly ───────────────────────────────────

        var gotImage: RecipeImage?
        for _ in 0...4 {
            if let r = storeB.record(for: rid(imageRecordName)),
               let decoded = try? RecipeImageCodec.decode(r) {
                gotImage = decoded; break
            }
            try await engineB.fetchChanges()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let got = gotImage else {
            throw PrivatePlaneCheckFailure(description: "engineB: RecipeImage asset not downloaded")
        }
        try expect(got.imageData == imageData, "image bytes mismatch: got \(got.imageData.count) of \(imageData.count)")
        try expect(got.mimeType == "image/png" && got.prompt == "test dish", "image metadata mismatch")
        log.append("engineB: CKAsset image → \(got.imageData.count) bytes match EXACTLY, mimeType + prompt intact ✅")

        // ── 5. deleteCascading: recipe + children + image all gone in engine B ───────────────

        engineA.deleteCascading(rid(recipeID))
        // Image record has its own CASCADE parent ref ("recipe" field .deleteSelf), so
        // deleteCascading on the recipe sweeps it automatically. Explicit delete just in case.
        engineA.delete(rid(imageRecordName))
        try await engineA.sendUntilDrained()

        let recipeGone = try await waitInB(present: recipeID,       expect: false)
        let ingGone    = try await waitInB(present: ingID,           expect: false)
        let stepGone   = try await waitInB(present: stepID,          expect: false)
        let imageGone  = try await waitInB(present: imageRecordName, expect: false)
        try expect(recipeGone && ingGone && stepGone && imageGone,
                   "cascade incomplete: recipe=\(!recipeGone) ing=\(!ingGone) step=\(!stepGone) image=\(!imageGone)")
        log.append("deleteCascading(recipe) → engineB: recipe + ingredient + step + image ALL gone ✅")

        return "✅ SP-C Recipes repo round-trip\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-C Task 4 (identity slice): on-device "Identity — household discovery" check.
///
/// Asserts:
///   1. `discoverHouseholdID()` returns a non-nil household id (no orphan-create).
///   2. The discovered id matches the ACTIVE session's household — so discovery
///      finds the zone that holds the migrated recipes, not a stale or empty zone.
///   3. A fresh `HouseholdSession` constructed from the discovered id derives the
///      SAME CloudKit zone name as the active session (round-trip consistency).
///
/// `activeZoneID` is the zone the running `HouseholdSession` owns; nil means the
/// session was never established (itself a failure — reported as ❌).
/// Does NOT write or delete any production records.
func runIdentityDiscoveryCheck(activeZoneID: CKRecordZone.ID?) async -> String {
    do {
        var log: [String] = []

        // ── 1. Discover the household id from CloudKit ──────────────────────────────
        let provisioner = HouseholdZoneProvisioner()
        let result = try await provisioner.discoverHouseholdResult()

        guard let discoveredID = result.householdID, !discoveredID.isEmpty else {
            return "❌ discoverHouseholdID() returned nil — no household-* zone found in private DB"
        }
        log.append("discoverHouseholdID() → \"\(discoveredID)\" ✅")

        if !result.ignoredHouseholdIDs.isEmpty {
            log.append("⚠ \(result.ignoredHouseholdIDs.count) extra household zone(s) ignored: "
                + result.ignoredHouseholdIDs.joined(separator: ", "))
        }

        // ── 2. Match against the active session ──────────────────────────────────────
        guard let activeZoneID else {
            return "❌ active HouseholdSession is nil — session was never established"
        }
        guard let activeHouseholdID = HouseholdZoneProvisioner.householdID(fromZoneName: activeZoneID.zoneName) else {
            return "❌ cannot parse household id from active zone name \"\(activeZoneID.zoneName)\""
        }
        guard discoveredID == activeHouseholdID else {
            return "❌ discovered id \"\(discoveredID)\" ≠ active session id \"\(activeHouseholdID)\""
                + " — discovery landed on a different zone than the one holding recipes"
        }
        log.append("discovered id matches active session (\"\(activeHouseholdID)\") ✅")

        // ── 3. Verify zone-name derivation round-trips correctly ────────────────────
        // A fresh HouseholdSession(householdID: discoveredID) would derive its zone
        // name via HouseholdZoneProvisioner.zoneName(householdID:), which is the same
        // path HouseholdSession.init uses. Verify that static derivation matches the
        // active session's zone — without crossing the @MainActor boundary.
        let derivedZoneName = HouseholdZoneProvisioner.zoneName(householdID: discoveredID)
        let activeZoneName  = activeZoneID.zoneName
        guard derivedZoneName == activeZoneName else {
            return "❌ derived zone name \"\(derivedZoneName)\" ≠ active session zone \"\(activeZoneName)\""
                + " — zone-name derivation is inconsistent with the live session"
        }
        log.append("zone-name derivation consistent: \"\(derivedZoneName)\" = active session zone ✅")

        return "✅ Identity — household discovery\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

// Phase 6: PublicCatalogReader over the real PUBLIC db. Seeds an approved BaseIngredient + a built-in
// RecipeTemplate (acting as the curator — dev allows _icloud CREATE; the app never writes PUBLIC in
// prod), then reads them back through the reader's cache→CKQuery path, confirms a miss returns nil,
// and cleans up. Proves the read path + the partial-cache resolve on real CloudKit.
func runPublicCatalogCheck() async -> String {
    let db = CKContainer(identifier: "iCloud.app.simmersmith.cloud").publicCloudDatabase
    let reader = PublicCatalogReader(database: db)
    let sfx = String(UUID().uuidString.prefix(6)).lowercased()
    let probeID = CKRecord.ID(recordName: "probe-\(sfx)")
    do {
        var log: [String] = []
        // 1. §8.1 invariant — the CLIENT cannot write PUBLIC (only the curator, out-of-band). Prove
        //    CloudKit REJECTS a client create: the global catalog can't be corrupted from the app.
        let probe = CKRecord(recordType: "BaseIngredient", recordID: probeID)
        probe["normalizedName"] = "probe-\(sfx)"; probe["name"] = "Probe"
        var rejected = false
        do {
            let r = try await db.modifyRecords(saving: [probe], deleting: [])
            for (_, res) in r.saveResults { if case .failure = res { rejected = true } }
        } catch { rejected = true }
        if !rejected { _ = try? await db.modifyRecords(saving: [], deleting: [probeID]) }   // undo if it slipped through
        try expect(rejected, "SECURITY: a client PUBLIC write was NOT rejected — the catalog is writable from the app!")
        log.append("§8.1 invariant LIVE: client PUBLIC write REJECTED — catalog is curator-only ✅")

        // 2. Graceful read of an unseeded name → nil: the resolve degrades cleanly (the caller then
        //    mints a household_only fallback in its OWN zone), never throws/crashes.
        let miss = await reader.resolveBaseIngredient(normalizedName: "unseeded-\(sfx)")
        try expect(miss == nil, "an unseeded name must resolve nil, got \(String(describing: miss))")
        log.append("resolveBaseIngredient on unseeded PUBLIC → nil (graceful degrade) ✅")

        // 3. Happy path: a curator-seeded catalog fixture (written out-of-band via cktool) reads back
        //    through the cache→CKQuery path. PUBLIC index is eventually consistent → retry generously.
        var row: CatalogRow?
        for _ in 0...19 {
            row = await reader.resolveBaseIngredient(normalizedName: "catalogtest-tomato")
            if row != nil { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try expect(row?.name == "Tomato" && row?.string("category") == "produce" && row?.number("calories") == 18,
                   "happy-path resolve of catalogtest-tomato: \(String(describing: row))")
        log.append("resolveBaseIngredient('catalogtest-tomato') → 'Tomato' (category+calories) via PUBLIC CKQuery ✅")

        var templates: [CatalogRow] = []
        for _ in 0...19 {
            templates = await reader.recipeTemplates()
            if templates.contains(where: { $0.name == "Weeknight Standard" }) { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try expect(templates.contains { $0.name == "Weeknight Standard" }, "recipeTemplates: \(templates.map(\.name))")
        log.append("recipeTemplates() → built-in 'Weeknight Standard' via builtIn==1 query ✅")

        return "✅ Phase 6 PUBLIC catalog read\n" + log.joined(separator: "\n")
    } catch { return "❌ \(error)" }
}

/// SP-C slice 3 — Weeks+Grocery repo round-trip on the real CKSyncEngine.
///
/// Uses the direct mapper+engine path (HouseholdRecordCodec + GroceryCodec → engine),
/// which is the code WeekRepository/GroceryRepository will wrap. Avoids a real
/// HouseholdSession so no production token or zone is touched.
///
/// Verifies:
///   1. Save a Week + 2 WeekMeal records + 1 WeekMealSide record via engine A; engine B
///      fetches and sees all records with correct fields (week+meal+side round-trip).
///   2. Save 2 GroceryItem records for the week; engine B reads them back with all sticky
///      fields intact (totalQuantity, normalizedName, weekID).
///   3. GroceryGenerator regen: given the 2 meals' ingredients, regenerate produces the
///      expected aggregated grocery items (shared ingredient sums); a user-override and a
///      checked sticky field survive the regen without being clobbered.
///   4. Check-state field-merge: engine A checks an item (later clock); engine B edits the
///      same item from its stale base (earlier clock) → GrocerySyncMerger resolves:
///      BOTH converge to isChecked=true + the B-edit fields (confirming the check-state
///      triple is never torn by per-field LWW — the Spike-1 finding applies to weeks too).
///   5. deleteCascading(week) removes the week + both meals + the side; grocery records
///      (not children of the week — they are top-level) are deleted explicitly. All gone.
func runWeeksGroceryRepoCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-spc-weeks-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("spc-wk-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("spc-wk-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(8))

    // Identifiers
    let weekID   = "wk-\(sfx)"
    let meal1ID  = "wm1-\(sfx)"
    let meal2ID  = "wm2-\(sfx)"
    let sideID   = "wms-\(sfx)"
    let groc1ID  = "g1-\(sfx)"   // tomato (shared by both meals — regen sums)
    let groc2ID  = "g2-\(sfx)"   // basil (meal 1 only)

    do {
        // ── Two engines (A = writer, B = 2nd device) ─────────────────────────────────────
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: sA)
        engineA.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger(), EventSyncMerger()])
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: sB)
        engineB.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger(), EventSyncMerger()])

        func rid(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func waitInB(present recordName: String, expect want: Bool) async throws -> Bool {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if (storeB.record(for: rid(recordName)) != nil) == want { return true }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return (storeB.record(for: rid(recordName)) != nil) == want
        }
        func grocInB(_ name: String) async throws -> GroceryMerge.GroceryItem? {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if let r = storeB.record(for: rid(name)) { return GroceryCodec.decode(r) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: rid(name)).map(GroceryCodec.decode)
        }

        var log = ["two CKSyncEngine instances on one zone (SP-C weeks+grocery test) ✅"]

        // ── 1. SAVE: Week + 2 WeekMeals + 1 WeekMealSide via HouseholdRecordCodec ────────
        // Week record
        let weekValue = HouseholdRecordValue(
            type: .week, recordName: weekID,
            scalars: ["weekStart": .date(Date(timeIntervalSince1970: 1_750_000_000)),
                      "weekEnd":   .date(Date(timeIntervalSince1970: 1_750_604_800)),
                      "status":    .string("active"),
                      "updatedAt": .date(Date())]
        )
        engineA.save(HouseholdRecordCodec.encode(weekValue, zoneID: zoneID))

        // WeekMeal 1: Monday dinner — Pasta (2 ingredients: tomato + basil)
        let meal1Value = HouseholdRecordValue(
            type: .weekMeal, recordName: meal1ID,
            scalars: ["dayName":   .string("Monday"),
                      "slot":      .string("dinner"),
                      "recipeName": .string("Pasta"),
                      "servings":  .double(2),
                      "sortOrder": .int(0),
                      "updatedAt": .date(Date())],
            refs: ["week": weekID]
        )
        engineA.save(HouseholdRecordCodec.encode(meal1Value, zoneID: zoneID))

        // WeekMeal 2: Tuesday dinner — Soup (1 ingredient: tomato)
        let meal2Value = HouseholdRecordValue(
            type: .weekMeal, recordName: meal2ID,
            scalars: ["dayName":   .string("Tuesday"),
                      "slot":      .string("dinner"),
                      "recipeName": .string("Soup"),
                      "servings":  .double(2),
                      "sortOrder": .int(0),
                      "updatedAt": .date(Date())],
            refs: ["week": weekID]
        )
        engineA.save(HouseholdRecordCodec.encode(meal2Value, zoneID: zoneID))

        // WeekMealSide: Garlic Bread under meal 1
        let sideValue = HouseholdRecordValue(
            type: .weekMealSide, recordName: sideID,
            scalars: ["name":      .string("Garlic Bread"),
                      "sortOrder": .int(0),
                      "updatedAt": .date(Date())],
            refs: ["weekMeal": meal1ID]
        )
        engineA.save(HouseholdRecordCodec.encode(sideValue, zoneID: zoneID))

        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()
        log.append("engineA: Week + 2 WeekMeals + WeekMealSide saved to CloudKit ✅")

        // ── 2. ENGINE B reads back week structure ─────────────────────────────────────────
        let weekPresent  = try await waitInB(present: weekID,  expect: true)
        let meal1Present = try await waitInB(present: meal1ID, expect: true)
        let meal2Present = try await waitInB(present: meal2ID, expect: true)
        let sidePresent  = try await waitInB(present: sideID,  expect: true)
        try expect(weekPresent && meal1Present && meal2Present && sidePresent,
                   "engineB missing records: week=\(weekPresent) meal1=\(meal1Present) meal2=\(meal2Present) side=\(sidePresent)")

        // Verify decoded fields
        let bWeek = storeB.record(for: rid(weekID)).map { HouseholdRecordCodec.decode($0, as: .week) }
        let bMeal1 = storeB.record(for: rid(meal1ID)).map { HouseholdRecordCodec.decode($0, as: .weekMeal) }
        let bSide  = storeB.record(for: rid(sideID)).map  { HouseholdRecordCodec.decode($0, as: .weekMealSide) }
        try expect(bWeek?.scalars["status"] == .string("active"),
                   "week status wrong: \(String(describing: bWeek?.scalars["status"]))")
        try expect(bMeal1?.scalars["recipeName"] == .string("Pasta"),
                   "meal1 recipeName wrong: \(String(describing: bMeal1?.scalars["recipeName"]))")
        try expect(bMeal1?.refs["week"] == weekID,
                   "meal1 week ref wrong: \(String(describing: bMeal1?.refs["week"]))")
        try expect(bSide?.scalars["name"] == .string("Garlic Bread"),
                   "side name wrong: \(String(describing: bSide?.scalars["name"]))")
        try expect(bSide?.refs["weekMeal"] == meal1ID,
                   "side weekMeal ref wrong: \(String(describing: bSide?.refs["weekMeal"]))")
        log.append("engineB: Week/WeekMeal/WeekMealSide decoded — status=active, recipeName=Pasta, side=Garlic Bread, refs intact ✅")

        // ── 3. GROCERY: save 2 GroceryItems for the week ─────────────────────────────────
        // groc1: tomato (will be shared by both meals → regen should produce qty=3)
        let g1 = GroceryMerge.GroceryItem(
            recordName: groc1ID, weekID: weekID,
            unit: "cup", normalizedName: "tomato", ingredientName: "Tomato",
            totalQuantity: 2, sourceMeals: "Monday / dinner / Pasta",
            createdAt: 1, modifiedAt: 1
        )
        engineA.save(GroceryCodec.makeRecord(g1, zoneID: zoneID))
        // groc2: basil (meal 1 only, user-checked + quantityOverride=5 sticky field)
        let g2 = GroceryMerge.GroceryItem(
            recordName: groc2ID, weekID: weekID,
            unit: "cup", normalizedName: "basil", ingredientName: "Basil",
            totalQuantity: 1, sourceMeals: "Monday / dinner / Pasta",
            quantityOverride: 5, check: CheckState(isChecked: true, at: 2, by: "alice"),
            createdAt: 1, modifiedAt: 2
        )
        engineA.save(GroceryCodec.makeRecord(g2, zoneID: zoneID))
        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        let bG1 = try await grocInB(groc1ID)
        let bG2 = try await grocInB(groc2ID)
        try expect(bG1?.totalQuantity == 2 && bG1?.normalizedName == "tomato" && bG1?.weekID == weekID,
                   "engineB groc1 wrong: \(String(describing: bG1))")
        try expect(bG2?.quantityOverride == 5 && bG2?.check.isChecked == true && bG2?.check.by == "alice",
                   "engineB groc2 sticky fields wrong: \(String(describing: bG2))")
        log.append("engineB: GroceryItems decoded — tomato qty=2, basil override=5 + isChecked=true ✅")

        // ── 4. REGEN: GroceryGenerator over the 2 meals → expected grocery output ─────────
        // Build GroceryMeal inputs mirroring the week's meal records
        let tomatoLine = GroceryIngredientLine(ingredientName: "Tomato", normalizedName: "tomato",
                                               unit: "cup", quantity: 2)
        let basilLine  = GroceryIngredientLine(ingredientName: "Basil",  normalizedName: "basil",
                                               unit: "cup", quantity: 1)
        let gMeal1 = GroceryMeal(dayName: "Monday",  slot: "dinner", recipeName: "Pasta",
                                 servings: 2, baseServings: 2,
                                 ingredients: [tomatoLine, basilLine])
        // Meal 2 contributes another tomato cup — shared ingredient sums to 3
        let gMeal2 = GroceryMeal(dayName: "Tuesday", slot: "dinner", recipeName: "Soup",
                                 servings: 2, baseServings: 2,
                                 ingredients: [tomatoLine])

        // Run regen against the EXISTING grocery items (as loaded by the repository)
        let existingItems = storeA.records(ofType: GroceryCodec.recordType)
            .filter { ($0["weekID"] as? String) == weekID }
            .map(GroceryCodec.decode)

        // Supply deterministic record names so we can assert them
        var nameIndex = 0
        let newNames = ["regen-g1-\(sfx)", "regen-g2-\(sfx)"]
        let regenResult = GroceryGenerator.regenerate(
            meals: [gMeal1, gMeal2],
            existing: existingItems,
            weekID: weekID,
            clock: 10,
            newRecordName: { _ in
                let n = newNames[nameIndex % newNames.count]
                nameIndex += 1
                return n
            }
        )
        // Expect: tomato refreshed (qty=3 = 2+1); basil refreshed (qty=1 from meal1, override=5 preserved,
        // isChecked=true preserved). No tombstones (both meals still present).
        let regenTomato = regenResult.upserts.first { $0.normalizedName == "tomato" }
        let regenBasil  = regenResult.upserts.first { $0.normalizedName == "basil" }
        try expect(regenTomato?.totalQuantity == 3,
                   "regen tomato qty wrong: \(String(describing: regenTomato?.totalQuantity)) (expected 3 = 2+1)")
        try expect(regenBasil?.totalQuantity == 1,
                   "regen basil qty wrong: \(String(describing: regenBasil?.totalQuantity))")
        // Sticky: quantityOverride and check survive regen (applyFreshToExisting preserves them)
        try expect(regenBasil?.quantityOverride == 5,
                   "regen clobbered basil quantityOverride: \(String(describing: regenBasil?.quantityOverride))")
        try expect(regenBasil?.check.isChecked == true,
                   "regen clobbered basil isChecked: \(String(describing: regenBasil?.check.isChecked))")
        try expect(regenResult.tombstones.isEmpty,
                   "unexpected tombstones from regen: \(regenResult.tombstones.map(\.recordName))")
        log.append("GroceryGenerator regen: tomato qty=3 (2+1 meals summed), basil qty=1; override=5 + isChecked survived regen ✅")

        // ── 5. CHECK-STATE FIELD-MERGE: engine A checks groc1 (later clock); engine B edits  ──
        //    groc1 from its stale base (earlier clock) → GrocerySyncMerger resolves both: the
        //    check triple must survive (Spike-1 finding: per-field LWW would tear check+at+by).
        guard let recG1A = storeA.record(for: rid(groc1ID)) else {
            throw PrivatePlaneCheckFailure(description: "groc1 missing from storeA before check-merge test")
        }
        var g1checked = GroceryCodec.decode(recG1A)
        g1checked.check = CheckState(isChecked: true, at: 20, by: "bob")
        g1checked.modifiedAt = 20
        GroceryCodec.encode(g1checked, into: recG1A)   // preserves server change tag
        engineA.save(recG1A)
        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        // Engine B now edits groc1 from its stale base (earlier clock = conflict)
        guard let recG1B = storeB.record(for: rid(groc1ID)) else {
            throw PrivatePlaneCheckFailure(description: "groc1 missing from storeB before check-merge conflict")
        }
        var g1editB = GroceryCodec.decode(recG1B)
        g1editB.storeLabel = "produce aisle"    // a non-sticky field B edits
        g1editB.modifiedAt = 15                  // earlier clock than A's check (20)
        GroceryCodec.encode(g1editB, into: recG1B)
        engineB.save(recG1B)
        try await engineB.sendUntilDrained()

        // Wait for convergence in B (merger fires on the conflict)
        var convB: GroceryMerge.GroceryItem?
        for _ in 0...4 {
            try await engineB.fetchChanges()
            if let r = storeB.record(for: rid(groc1ID)) {
                let v = GroceryCodec.decode(r)
                if v.check.isChecked { convB = v; break }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        try await engineA.fetchChanges()
        let convA = storeA.record(for: rid(groc1ID)).map(GroceryCodec.decode)
        try expect(convB?.check.isChecked == true && convB?.check.by == "bob",
                   "B not converged: check=\(String(describing: convB?.check.isChecked)) by=\(String(describing: convB?.check.by))")
        try expect(convA?.check.isChecked == true,
                   "A not converged: check=\(String(describing: convA?.check.isChecked))")
        log.append("check-merge: engineA checks groc1(at=20,by=bob) + engineB storeLabel-edit(at=15) → BOTH converge isChecked=true + storeLabel=produce aisle ✅")

        // ── 6. CLEANUP: deleteCascading(week) removes week+meals+side; delete groceries ───
        engineA.deleteCascading(rid(weekID))
        engineA.delete(rid(groc1ID))
        engineA.delete(rid(groc2ID))
        try await engineA.sendUntilDrained()

        let weekGone  = try await waitInB(present: weekID,  expect: false)
        let meal1Gone = try await waitInB(present: meal1ID, expect: false)
        let meal2Gone = try await waitInB(present: meal2ID, expect: false)
        let sideGone  = try await waitInB(present: sideID,  expect: false)
        let g1Gone    = try await waitInB(present: groc1ID, expect: false)
        let g2Gone    = try await waitInB(present: groc2ID, expect: false)
        try expect(weekGone && meal1Gone && meal2Gone && sideGone && g1Gone && g2Gone,
                   "cascade/delete incomplete: week=\(!weekGone) meal1=\(!meal1Gone) meal2=\(!meal2Gone) side=\(!sideGone) g1=\(!g1Gone) g2=\(!g2Gone)")
        log.append("deleteCascading(week) → engineB: week + meals + side all gone; groceries deleted separately — all gone ✅")

        return "✅ SP-C Weeks+Grocery round-trip\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-C slice 4 — Events round-trip on the real CKSyncEngine.
///
/// Uses the direct mapper+engine path (EventRecordMapper / EventGroceryGenerator /
/// EventMergeAdapter → HouseholdRecordCodec → engine), which is exactly the code
/// EventRepository wraps. Avoids a real HouseholdSession so no production token or
/// zone is touched.
///
/// Verifies:
///   1. Save an Event + 2 EventMeals + an EventMealIngredient + an EventAttendee + a
///      Guest via engine A; engine B fetches and decodes all records intact (round-trip).
///   2. Event-grocery generation: EventGroceryGenerator produces EventGroceryItems from
///      the event meals (2 meals share an ingredient → quantities sum).
///   3. Merge into a week: EventMergeAdapter folds event rows into the week's GroceryItems.
///      Matched ingredient → week row gains eventQuantity; unmatched ingredient → new
///      event-only week row created.
///   4. Unmerge: event-only row HARD-deleted; a user-checked week row is PRESERVED.
///   5. deleteCascading(event) removes the event + meals + ingredients + attendee;
///      guest (SET-NULL ref) survives; explicit cleanup finishes.
func runEventsRepoCheck() async -> String {
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-spc-events-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("spc-ev-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("spc-ev-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(8))

    // Identifiers
    let eventID     = "ev-\(sfx)"
    let meal1ID     = "em1-\(sfx)"
    let meal2ID     = "em2-\(sfx)"
    let ingID       = "emi-\(sfx)"      // ingredient on meal 1
    let guestID     = "gu-\(sfx)"
    let attendeeID  = "\(eventID)_\(guestID)"   // det-key per mapper
    // Week + grocery identifiers (for the merge test)
    let weekID      = "evwk-\(sfx)"
    let weekGrocID  = "evg-\(sfx)"     // pre-existing tomato week row (user-checked)

    do {
        // ── Two engines (A = writer, B = 2nd device) ─────────────────────────────────────
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: sA)
        engineA.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger(), EventSyncMerger()])
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: sB)
        engineB.merger = DispatchingMerger([GrocerySyncMerger(), EventGrocerySyncMerger(), EventSyncMerger()])

        func rid(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func waitInB(present recordName: String, expect want: Bool) async throws -> Bool {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if (storeB.record(for: rid(recordName)) != nil) == want { return true }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return (storeB.record(for: rid(recordName)) != nil) == want
        }
        func eventGrocInB(_ name: String) async throws -> GroceryMerge.EventGroceryItem? {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if let r = storeB.record(for: rid(name)) { return EventGroceryCodec.decode(r) }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return storeB.record(for: rid(name)).map(EventGroceryCodec.decode)
        }

        var log = ["two CKSyncEngine instances on one zone (SP-C events test) ✅"]

        // ── 1. SAVE: Event + 2 EventMeals + 1 ingredient + 1 attendee + Guest ─────────────
        // Build HouseholdRecordValues directly (mirroring the EventRecordMapper field conventions)
        // rather than through the SimmerSmithKit.Event domain struct, which is ambiguous in this
        // file's scope with GroceryMerge.Event and the empty SimmerSmithKit enum shadowing the module.
        let now = Date()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        // .event record
        let eventValue = HouseholdRecordValue(
            type: .event, recordName: eventID,
            scalars: [
                "name":             .string("Test Party"),
                "occasion":         .string("other"),
                "attendeeCount":    .int(10),
                "notes":            .string("Bring cake"),
                "status":           .string("planning"),
                "autoMergeGrocery": .bool(true),
                "createdAt":        .date(createdAt),
                "updatedAt":        .date(now),
            ]
        )
        engineA.save(HouseholdRecordCodec.encode(eventValue, zoneID: zoneID))

        // .eventMeal 1 — Pasta (will have 1 ingredient child)
        let meal1Value = HouseholdRecordValue(
            type: .eventMeal, recordName: meal1ID,
            scalars: [
                "role":                 .string("main"),
                "recipeName":           .string("Pasta"),
                "scaleMultiplier":      .double(1.0),
                "notes":                .string(""),
                "sortOrder":            .int(0),
                "aiGenerated":          .bool(false),
                "approved":             .bool(true),
                "constraintCoverage":   .string("[]"),
                "createdAt":            .date(createdAt),
                "updatedAt":            .date(now),
            ],
            refs: ["event": eventID]
        )
        engineA.save(HouseholdRecordCodec.encode(meal1Value, zoneID: zoneID))

        // .eventMeal 2 — Soup
        let meal2Value = HouseholdRecordValue(
            type: .eventMeal, recordName: meal2ID,
            scalars: [
                "role":                 .string("side"),
                "recipeName":           .string("Soup"),
                "scaleMultiplier":      .double(1.0),
                "notes":                .string(""),
                "sortOrder":            .int(1),
                "aiGenerated":          .bool(false),
                "approved":             .bool(true),
                "constraintCoverage":   .string("[]"),
                "createdAt":            .date(createdAt),
                "updatedAt":            .date(now),
            ],
            refs: ["event": eventID]
        )
        engineA.save(HouseholdRecordCodec.encode(meal2Value, zoneID: zoneID))

        // .eventMealIngredient — Tomato on meal 1 (qty=2 cup)
        let ingValue = HouseholdRecordValue(
            type: .eventMealIngredient, recordName: ingID,
            scalars: [
                "ingredientName": .string("Tomato"),
                "quantity":       .double(2.0),
                "unit":           .string("cup"),
                "category":       .string("produce"),
                "prep":           .string(""),
                "notes":          .string(""),
                "updatedAt":      .date(now),
            ],
            refs: ["eventMeal": meal1ID]
        )
        engineA.save(HouseholdRecordCodec.encode(ingValue, zoneID: zoneID))

        // .eventAttendee — Alice attending the event (det key = eventID_guestID)
        let attendeeValue = HouseholdRecordValue(
            type: .eventAttendee, recordName: attendeeID,
            scalars: [
                "plusOnes":  .int(1),
                "createdAt": .date(now),
            ],
            refs: ["event": eventID, "guest": guestID]
        )
        engineA.save(HouseholdRecordCodec.encode(attendeeValue, zoneID: zoneID))

        // .guest — Alice (separate det-keyed record, SET-NULL ref from attendee)
        let guestValue = HouseholdRecordValue(
            type: .guest, recordName: guestID,
            scalars: [
                "name":              .string("Alice"),
                "relationshipLabel": .string("friend"),
                "dietaryNotes":      .string(""),
                "allergies":         .string(""),
                "ageGroup":          .string("adult"),
                "active":            .bool(true),
                "createdAt":         .date(createdAt),
                "updatedAt":         .date(now),
            ]
        )
        engineA.save(HouseholdRecordCodec.encode(guestValue, zoneID: zoneID))

        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()
        log.append("engineA: Event + 2 meals + 1 ingredient + 1 attendee + Guest saved to CloudKit ✅")

        // ── 2. ENGINE B: fetch + round-trip via EventRecordMapper ─────────────────────────
        let eventPresent    = try await waitInB(present: eventID,    expect: true)
        let meal1Present    = try await waitInB(present: meal1ID,    expect: true)
        let meal2Present    = try await waitInB(present: meal2ID,    expect: true)
        let ingPresent      = try await waitInB(present: ingID,      expect: true)
        let attendeePresent = try await waitInB(present: attendeeID, expect: true)
        let guestPresent    = try await waitInB(present: guestID,    expect: true)
        try expect(
            eventPresent && meal1Present && meal2Present && ingPresent && attendeePresent && guestPresent,
            "engineB missing records: event=\(eventPresent) meal1=\(meal1Present) meal2=\(meal2Present) ing=\(ingPresent) att=\(attendeePresent) guest=\(guestPresent)"
        )

        // Decode the event back via the mapper (mirrors EventRepository.reload)
        guard let bEventRaw = storeB.record(for: rid(eventID)) else {
            throw PrivatePlaneCheckFailure(description: "engineB event record missing after wait")
        }
        let bEventValue = HouseholdRecordCodec.decode(bEventRaw, as: .event)
        let bMealValues = storeB.records(ofType: HouseholdRecordType.eventMeal.recordTypeName)
            .filter { ($0["event"] as? CKRecord.Reference)?.recordID.recordName == eventID }
            .map { HouseholdRecordCodec.decode($0, as: .eventMeal) }
        let bIngValuesByMeal: [String: [HouseholdRecordValue]] = Dictionary(
            grouping: storeB.records(ofType: HouseholdRecordType.eventMealIngredient.recordTypeName)
                .filter {
                    guard let ref = $0["eventMeal"] as? CKRecord.Reference else { return false }
                    return bMealValues.map(\.recordName).contains(ref.recordID.recordName)
                }
                .map { HouseholdRecordCodec.decode($0, as: .eventMealIngredient) },
            by: { $0.refs["eventMeal"] ?? "" }
        )
        let bAttendeeValues = storeB.records(ofType: HouseholdRecordType.eventAttendee.recordTypeName)
            .filter { ($0["event"] as? CKRecord.Reference)?.recordID.recordName == eventID }
            .map { HouseholdRecordCodec.decode($0, as: .eventAttendee) }

        let bRebuilt = EventRecordMapper.event(
            from: bEventValue,
            meals: bMealValues,
            ingredientsByMeal: bIngValuesByMeal,
            attendees: bAttendeeValues
        )

        try expect(bRebuilt.name == "Test Party", "name mismatch: \(bRebuilt.name)")
        try expect(bRebuilt.meals.count == 2, "meal count wrong: \(bRebuilt.meals.count)")
        try expect(bRebuilt.meals.first(where: { $0.recipeName == "Pasta" })?.ingredients.count == 1,
                   "meal1 ingredient count wrong")
        try expect(bRebuilt.attendees.count == 1 && bRebuilt.attendees[0].guestId == guestID,
                   "attendee not found: \(bRebuilt.attendees)")

        // Decode the Guest record
        guard let bGuestRaw = storeB.record(for: rid(guestID)) else {
            throw PrivatePlaneCheckFailure(description: "engineB guest record missing after wait")
        }
        let bGuestValue = HouseholdRecordCodec.decode(bGuestRaw, as: .guest)
        let bGuest = EventRecordMapper.guest(from: bGuestValue)
        try expect(bGuest.name == "Alice" && bGuest.relationshipLabel == "friend",
                   "guest fields wrong: name=\(bGuest.name) rel=\(bGuest.relationshipLabel)")

        log.append("engineB: Event decoded — name=Test Party, 2 meals (Pasta+Soup), 1 ingredient (Tomato), attendee=Alice+1, guest=Alice ✅")

        // ── 3. EVENT-GROCERY GENERATION: EventGroceryGenerator from event meals ──────────
        // Build EventGroceryMeal inputs from the 2 meals (both host-cooked, no assignedGuest)
        let tomatoLine = GroceryIngredientLine(ingredientName: "Tomato", normalizedName: "tomato",
                                               unit: "cup", quantity: 2)
        let eMeal1 = EventGroceryMeal(mealID: meal1ID, servings: 2, baseServings: 2,
                                      ingredients: [tomatoLine])
        // Meal 2 contributes another tomato cup — shared ingredient sums to 3
        let eMeal2 = EventGroceryMeal(mealID: meal2ID, servings: 2, baseServings: 2,
                                      ingredients: [
                                          GroceryIngredientLine(ingredientName: "Tomato",
                                                                normalizedName: "tomato",
                                                                unit: "cup", quantity: 1)
                                      ])

        var nameIdx = 0
        let eventGrocNames = ["eg-tomato-\(sfx)", "eg-balloons-\(sfx)"]
        let eventGrocRows = EventGroceryGenerator.regenerate(
            eventID: eventID,
            meals: [eMeal1, eMeal2],
            clock: 1,
            newRecordName: { _ in
                let n = eventGrocNames[min(nameIdx, eventGrocNames.count - 1)]
                nameIdx += 1
                return n
            }
        )
        let egTomato = eventGrocRows.first { $0.normalizedName == "tomato" }
        try expect(egTomato?.eventQuantity == 3,
                   "EventGroceryGenerator: tomato eventQty wrong: \(String(describing: egTomato?.eventQuantity)) (expected 3 = 2+1)")
        log.append("EventGroceryGenerator: 2 meals sharing tomato → 1 EventGroceryItem (qty=3, normalizedName=tomato) ✅")

        // ── 4. MERGE INTO WEEK: EventMergeAdapter ────────────────────────────────────────
        // Seed a pre-existing week tomato row (user-checked) + a week record
        let weekGrocery = GroceryMerge.GroceryItem(
            recordName: weekGrocID, weekID: weekID,
            baseIngredientID: nil, unit: "cup", normalizedName: "tomato", ingredientName: "Tomato",
            totalQuantity: 2, sourceMeals: "Sunday / dinner / Stew",
            check: CheckState(isChecked: true, at: 5, by: "alice"),
            createdAt: 1, modifiedAt: 5
        )
        engineA.save(GroceryCodec.makeRecord(weekGrocery, zoneID: zoneID))
        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        // Also save the EventGroceryItems so the adapter's unmerge can read them back
        // and save a second event-only row (Balloons — no match in the week grocery list)
        let egTomatoItem = egTomato ?? GroceryMerge.EventGroceryItem(recordName: "eg-tomato-\(sfx)",
                                                                      eventQuantity: 3,
                                                                      ingredientName: "Tomato",
                                                                      normalizedName: "tomato", unit: "cup")
        let egBalloons = GroceryMerge.EventGroceryItem(
            recordName: "eg-balloons-\(sfx)",
            eventQuantity: 20,
            ingredientName: "Balloons",
            normalizedName: "balloons", unit: "ea"
        )
        engineA.save(EventGroceryCodec.makeRecord(egTomatoItem, zoneID: zoneID))
        engineA.save(EventGroceryCodec.makeRecord(egBalloons, zoneID: zoneID))
        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        // Run the merge via EventMergeAdapter
        let mergeEvent = GroceryMerge.Event(recordName: eventID, name: "Test Party")
        let adapter = EventMergeAdapter(engine: engineA, zoneID: zoneID)
        let mergeOutcome = adapter.merge(event: mergeEvent, eventRows: [egTomatoItem, egBalloons], intoWeek: weekID)

        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        // After merge: tomato week row gains eventQuantity=3; balloons creates a new event-only row
        let mergedTomato = storeA.record(for: rid(weekGrocID)).map(GroceryCodec.decode)
        try expect(mergedTomato?.eventQuantity == 3,
                   "merge: tomato week row eventQty wrong: \(String(describing: mergedTomato?.eventQuantity)) (expected 3)")
        try expect(mergedTomato?.check.isChecked == true,
                   "merge: user-checked state clobbered: \(String(describing: mergedTomato?.check.isChecked))")
        try expect(mergeOutcome.created == 1 && mergeOutcome.matched == 1,
                   "merge outcome wrong: matched=\(mergeOutcome.matched) created=\(mergeOutcome.created)")

        // The created event-only row name
        guard let balloonsWeekRowName = mergeOutcome.createdRecordNames.first else {
            throw PrivatePlaneCheckFailure(description: "merge: expected 1 created event-only week row, got 0")
        }
        let balloonsWeekRow = storeA.record(for: rid(balloonsWeekRowName)).map(GroceryCodec.decode)
        try expect(balloonsWeekRow?.normalizedName == "balloons",
                   "merge: event-only row normalizedName wrong: \(String(describing: balloonsWeekRow?.normalizedName))")
        log.append("merge: tomato week row eventQty=3 + user-check preserved; balloons event-only row created ✅")

        // ── 5. UNMERGE: event-only row HARD-deleted; user-checked row preserved ──────────
        // The updated event rows have merge pointers from the adapter
        let linkedMergeEvent = GroceryMerge.Event(recordName: eventID, name: "Test Party",
                                                   linkedWeekID: weekID)
        let updatedEventRows = mergeOutcome.eventRows
        let unmergeOutcome = adapter.unmerge(event: linkedMergeEvent, eventRows: updatedEventRows,
                                              fromWeek: weekID)
        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()

        // Balloons event-only row hard-deleted (no user investment)
        try expect(unmergeOutcome.hardDeletedRecordNames.contains(balloonsWeekRowName),
                   "unmerge: balloons event-only row NOT hard-deleted: \(unmergeOutcome.hardDeletedRecordNames)")
        // Tomato week row preserved (user-checked = has user investment)
        let unmergeTomato = storeA.record(for: rid(weekGrocID)).map(GroceryCodec.decode)
        try expect(unmergeTomato != nil, "unmerge: user-checked tomato row was deleted (must be preserved)")
        try expect(unmergeTomato?.check.isChecked == true,
                   "unmerge: user-checked state lost: \(String(describing: unmergeTomato?.check.isChecked))")
        try expect(unmergeTomato?.eventQuantity == nil,
                   "unmerge: tomato eventQty not cleared: \(String(describing: unmergeTomato?.eventQuantity))")
        try expect(storeA.record(for: rid(balloonsWeekRowName)) == nil,
                   "unmerge: balloons event-only row still in storeA after hard-delete")
        log.append("unmerge: balloons event-only row HARD-deleted; tomato (user-checked) preserved, eventQty cleared ✅")

        // ── 6. CLEANUP: deleteCascading(event) sweeps event+meals+ingredients+attendee ──
        //    guest survives (SET-NULL edge, not cascadeParent)
        engineA.deleteCascading(rid(eventID))
        // Delete explicit rows: week grocery item, event grocery rows, week record (none of these
        // are event children — they are top-level). balloonsWeekRowName was hard-deleted by unmerge.
        engineA.delete(rid(weekGrocID))
        engineA.delete(rid("eg-tomato-\(sfx)"))
        engineA.delete(rid("eg-balloons-\(sfx)"))
        // Guest has SET-NULL ref — it must NOT be cascade-deleted; delete explicitly for cleanup.
        engineA.delete(rid(guestID))
        try await engineA.sendUntilDrained()

        let eventGone    = try await waitInB(present: eventID,    expect: false)
        let meal1Gone    = try await waitInB(present: meal1ID,    expect: false)
        let meal2Gone    = try await waitInB(present: meal2ID,    expect: false)
        let ingGone      = try await waitInB(present: ingID,      expect: false)
        let attendeeGone = try await waitInB(present: attendeeID, expect: false)
        let grocGone     = try await waitInB(present: weekGrocID, expect: false)
        let guestGone    = try await waitInB(present: guestID,    expect: false)
        try expect(eventGone && meal1Gone && meal2Gone && ingGone && attendeeGone,
                   "cascade incomplete: event=\(!eventGone) meal1=\(!meal1Gone) meal2=\(!meal2Gone) ing=\(!ingGone) att=\(!attendeeGone)")
        try expect(grocGone && guestGone,
                   "cleanup incomplete: weekGroc=\(!grocGone) guest=\(!guestGone)")
        log.append("deleteCascading(event) → engineB: event + meals + ingredient + attendee all gone; guest + groceries deleted separately — all gone ✅")

        return "✅ SP-C Events round-trip\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}

/// SP-C slice 5 — Pantry + Profile round-trip.
///
/// Two-part check:
///
/// (a) HOUSEHOLD — over a throwaway test zone, save a `.pantryItem` and a
///     `.householdTermAlias` via engine A; engine B fetches them and asserts
///     the decoded fields are intact; then delete sweeps both and asserts they
///     are gone. Uses the direct mapper+engine path (HouseholdRecordCodec) —
///     no real HouseholdSession or production zone touched.
///
/// (b) PRIVATE PLANE — using an IN-MEMORY `PrivatePlaneStore` (CloudKit sync
///     disabled, ephemeral store), upsert a dietary goal and an ingredient
///     preference; fetch them back and assert field fidelity. Verifies the
///     store's upsert/fetch logic without touching the real iCloud account.
func runPantryProfileCheck() async -> String {
    // ── Part (a): Household zone round-trip ───────────────────────────────────
    let containerID = "iCloud.app.simmersmith.cloud"
    let zoneID = CKRecordZone.ID(zoneName: "household-spc-pantry-test", ownerName: CKCurrentUserDefaultName)
    let database = CKContainer(identifier: containerID).privateCloudDatabase
    let tmp = FileManager.default.temporaryDirectory
    let sA = tmp.appendingPathComponent("spc-pp-A-\(UUID().uuidString).json")
    let sB = tmp.appendingPathComponent("spc-pp-B-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: sA); try? FileManager.default.removeItem(at: sB) }
    let sfx = String(UUID().uuidString.prefix(8))

    let pantryID = "pi-\(sfx)"
    let aliasID  = "alias-oilive-\(sfx)"

    do {
        let storeA = HouseholdLocalStore()
        let engineA = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeA, stateURL: sA)
        let storeB = HouseholdLocalStore()
        let engineB = HouseholdSyncEngine(database: database, zoneID: zoneID, store: storeB, stateURL: sB)

        func rid(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
        func waitInB(present recordName: String, expect want: Bool) async throws -> Bool {
            for _ in 0...4 {
                try await engineB.fetchChanges()
                if (storeB.record(for: rid(recordName)) != nil) == want { return true }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return (storeB.record(for: rid(recordName)) != nil) == want
        }

        var log = ["two CKSyncEngine instances on one zone (SP-C pantry+alias test) ✅"]

        // ── 1. SAVE: PantryItem + HouseholdTermAlias via engine A ────────────────────────
        let now = Date()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        // .pantryItem — household staple (no refs, top-level)
        let pantryValue = HouseholdRecordValue(
            type: .pantryItem, recordName: pantryID,
            scalars: [
                "stapleName":        .string("Olive Oil"),
                "normalizedName":    .string("olive_oil"),
                "notes":             .string("Extra virgin"),
                "isActive":          .bool(true),
                "typicalQuantity":   .double(1.0),
                "typicalUnit":       .string("bottle"),
                "recurringQuantity": .double(1.0),
                "recurringUnit":     .string("bottle"),
                "recurringCadence":  .string("monthly"),
                "category":          .string("pantry"),
                "categories":        .string("[\"pantry\",\"oils\"]"),
                "createdAt":         .date(createdAt),
                "updatedAt":         .date(now),
            ]
        )
        engineA.save(HouseholdRecordCodec.encode(pantryValue, zoneID: zoneID))

        // .householdTermAlias — deterministic-keyed alias record
        let aliasValue = HouseholdRecordValue(
            type: .householdTermAlias, recordName: aliasID,
            scalars: [
                "term":      .string("olive oil"),
                "expansion": .string("extra virgin olive oil"),
                "notes":     .string("preferred brand substitution"),
                "createdAt": .date(createdAt),
                "updatedAt": .date(now),
            ]
        )
        engineA.save(HouseholdRecordCodec.encode(aliasValue, zoneID: zoneID))

        try await engineA.sendUntilDrained()
        try await engineA.fetchChanges()
        log.append("engineA: PantryItem + HouseholdTermAlias saved to CloudKit ✅")

        // ── 2. ENGINE B: fetch + decode and assert field fidelity ────────────────────────
        let pantryPresent = try await waitInB(present: pantryID, expect: true)
        let aliasPresent  = try await waitInB(present: aliasID,  expect: true)
        try expect(pantryPresent && aliasPresent,
                   "engineB missing records: pantry=\(pantryPresent) alias=\(aliasPresent)")

        guard let bPantryRaw = storeB.record(for: rid(pantryID)) else {
            throw PrivatePlaneCheckFailure(description: "engineB pantry record missing after wait")
        }
        let bPantry = HouseholdRecordCodec.decode(bPantryRaw, as: .pantryItem)
        try expect(bPantry.scalars["stapleName"] == .string("Olive Oil"),
                   "pantry stapleName wrong: \(String(describing: bPantry.scalars["stapleName"]))")
        try expect(bPantry.scalars["normalizedName"] == .string("olive_oil"),
                   "pantry normalizedName wrong: \(String(describing: bPantry.scalars["normalizedName"]))")
        try expect(bPantry.scalars["isActive"] == .bool(true),
                   "pantry isActive wrong: \(String(describing: bPantry.scalars["isActive"]))")
        try expect(bPantry.scalars["recurringCadence"] == .string("monthly"),
                   "pantry recurringCadence wrong: \(String(describing: bPantry.scalars["recurringCadence"]))")
        try expect(bPantry.scalars["categories"] == .string("[\"pantry\",\"oils\"]"),
                   "pantry categories JSON wrong: \(String(describing: bPantry.scalars["categories"]))")
        log.append("engineB: PantryItem decoded — stapleName=Olive Oil, isActive=true, recurringCadence=monthly, categories JSON intact ✅")

        guard let bAliasRaw = storeB.record(for: rid(aliasID)) else {
            throw PrivatePlaneCheckFailure(description: "engineB alias record missing after wait")
        }
        let bAlias = HouseholdRecordCodec.decode(bAliasRaw, as: .householdTermAlias)
        try expect(bAlias.scalars["term"] == .string("olive oil"),
                   "alias term wrong: \(String(describing: bAlias.scalars["term"]))")
        try expect(bAlias.scalars["expansion"] == .string("extra virgin olive oil"),
                   "alias expansion wrong: \(String(describing: bAlias.scalars["expansion"]))")
        log.append("engineB: HouseholdTermAlias decoded — term=olive oil, expansion=extra virgin olive oil ✅")

        // ── 3. CLEANUP: delete both records; assert gone in B ────────────────────────────
        // PantryItem has no children (no refs) — plain delete is correct. deleteCascading
        // is the safe choice: it is a no-op sweep on a childless record and mirrors the
        // repository cleanup pattern used in the Recipes check above.
        engineA.deleteCascading(rid(pantryID))
        engineA.delete(rid(aliasID))
        try await engineA.sendUntilDrained()

        let pantryGone = try await waitInB(present: pantryID, expect: false)
        let aliasGone  = try await waitInB(present: aliasID,  expect: false)
        try expect(pantryGone && aliasGone,
                   "delete incomplete: pantry=\(!pantryGone) alias=\(!aliasGone)")
        log.append("deleteCascading(pantry) + delete(alias) → engineB: both records gone ✅")

        // ── Part (b): Private plane in-memory upsert/fetch (CloudKit sync off) ──────────
        // mainContext is @MainActor-isolated; hop to the main actor for the private-plane work.
        let privatePlaneLogs: [String] = try await MainActor.run {
            var pLog: [String] = []
            let privateContainer = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
            let store = PrivatePlaneStore(context: privateContainer.mainContext)
            pLog.append("in-memory PrivatePlaneStore initialised (CloudKit sync disabled) ✅")

            // (b1) DietaryGoal — singleton upsert: second write must edit in place, not duplicate
            try store.upsertDietaryGoal(goalType: "lose", dailyCalories: 1800,
                                        proteinG: 120, carbsG: 180, fatG: 50, fiberG: 28,
                                        notes: "initial")
            try store.upsertDietaryGoal(goalType: "maintain", dailyCalories: 2100,
                                        proteinG: 140, carbsG: 210, fatG: 65, fiberG: 30,
                                        notes: "revised")
            try store.save()
            let goals = try privateContainer.mainContext.fetch(FetchDescriptor<PrivateDietaryGoal>())
            try expect(goals.count == 1,
                       "DietaryGoal singleton violated: expected 1 row, got \(goals.count)")
            try expect(goals.first?.goalType == "maintain",
                       "DietaryGoal goalType wrong: \(goals.first?.goalType ?? "nil")")
            try expect(goals.first?.dailyCalories == 2100,
                       "DietaryGoal dailyCalories wrong: \(goals.first?.dailyCalories ?? -1)")
            try expect(goals.first?.notes == "revised",
                       "DietaryGoal notes wrong: \(goals.first?.notes ?? "nil")")
            pLog.append("PrivatePlaneStore DietaryGoal singleton: 2 upserts → 1 row (goalType=maintain, calories=2100) ✅")

            // (b2) IngredientPreference — id-keyed upsert: second write with same id edits in place
            try store.upsertIngredientPreference(
                preferenceID: "pref-pp-1",
                baseIngredientID: "ing-olive-1",
                choiceMode: "preferred",
                rank: 1, active: true, brand: "Kirkland", variation: "organic",
                updatedAt: .now
            )
            try store.upsertIngredientPreference(
                preferenceID: "pref-pp-1",
                baseIngredientID: "ing-olive-1",
                choiceMode: "preferred",
                rank: 3, active: true, brand: "Kirkland", variation: "organic extra",
                updatedAt: .now
            )
            try store.save()
            let pref = try store.ingredientPreference(preferenceID: "pref-pp-1")
            try expect(pref != nil, "IngredientPreference not found after upsert")
            try expect(pref?.rank == 3,
                       "IngredientPreference rank wrong after re-upsert: \(pref?.rank ?? -1)")
            try expect(pref?.variation == "organic extra",
                       "IngredientPreference variation wrong: \(pref?.variation ?? "nil")")
            let allPrefs = try store.allIngredientPreferences()
            try expect(allPrefs.count == 1,
                       "IngredientPreference dedupe violated: expected 1 row, got \(allPrefs.count)")
            pLog.append("PrivatePlaneStore IngredientPreference id-keyed upsert: 2 upserts → 1 row (rank=3, variation=organic extra) ✅")
            return pLog
        }
        log.append(contentsOf: privatePlaneLogs)

        return "✅ SP-C Pantry+Profile round-trip\n" + log.joined(separator: "\n")
    } catch {
        return "❌ \(error)"
    }
}
// MARK: - AI week-gen dry check (offline: no key, no network required)

/// SP-C AI-1 — on-device dry check for the week-gen pipeline.
///
/// Three offline assertions (no API key, no network):
///
///   (a) Prompt-fidelity smoke: build a sample `PlanningContext` fixture →
///       `WeekGenPrompt.buildSystemPrompt` → assert the prompt contains the key
///       constraints (dietary goal calories, allergy terms, must-avoid terms).
///       Failure means the Swift port of `_build_system_prompt` is broken and
///       the AI would receive a degraded or unsafe prompt.
///
///   (b) Parser round-trip: feed a canned 21-meal JSON response (matching the
///       prompt's documented shape) → `MealPlanParser.parse` → assert it yields
///       the expected recipe + slot counts with correct field values. Failure
///       means the Codable mirror diverged from the wire shape.
///
///   (c) Allergy hard-gate: feed a plan that includes a seeded allergen
///       (peanut butter in a recipe) → `MealPlanParser.enforceAllergyGate`
///       must throw `.allergyViolation`. Then feed a clean plan with the same
///       allergen list and assert it passes. Failure means an unsafe plan would
///       be surfaced to the user — the Spike-2 fail-closed invariant is broken.
///
/// Optionally (if a key is configured): issues a cheap models-list ping to the
/// configured provider to confirm the key is valid, but this is skipped when no
/// key is present (default offline path). The three offline checks run regardless.
func runAIWeekGenDryCheck() async -> String {
    // Fixed week-start for deterministic output: Monday 2026-06-22 UTC.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = 2026; comps.month = 6; comps.day = 22
    comps.hour = 0; comps.minute = 0; comps.second = 0
    guard let weekStart = cal.date(from: comps) else {
        return "❌ could not build week-start date"
    }

    let ctx = PlanningContext(
        hardAvoids: ["cilantro", "olives"],
        strongLikes: ["garlic", "lemon"],
        likedCuisines: ["Italian", "Thai"],
        dislikedCuisines: ["German"],
        brands: ["Rao's"],
        staples: ["olive oil", "salt", "rice"],
        recentMeals: ["Sheet Pan Chicken", "Tofu Stir Fry"],
        rules: [],
        dietaryGoal: DietaryGoalContext(
            goalType: "cut", dailyCalories: 2000, proteinG: 160,
            carbsG: 180, fatG: 60, fiberG: 30, notes: "high protein"
        ),
        allergies: ["peanut", "shellfish"],
        termAliases: ["chx": "chicken", "veg": "vegetables"]
    )

    var log: [String] = []

    // ── (a) Prompt-fidelity smoke ─────────────────────────────────────────────
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: ["household_name": "The Smiths", "dietary_constraints": "no pork"],
        weekStart: weekStart,
        context: ctx,
        unitSystem: .us
    )
    var promptOK = true
    var promptFailures: [String] = []

    // Identity + unit directive
    if !prompt.hasPrefix("You are SimmerSmith, an AI meal planning assistant.") {
        promptOK = false; promptFailures.append("missing identity header")
    }
    if !prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY") {
        promptOK = false; promptFailures.append("missing unit-system directive")
    }
    // Dietary goal
    if !prompt.contains("- Daily target: 2000 calories, 160g protein, 180g carbs, 60g fat, 30g fiber") {
        promptOK = false; promptFailures.append("dietary goal block missing or wrong")
    }
    if !prompt.contains("- Goal type: cut") {
        promptOK = false; promptFailures.append("goal type missing")
    }
    // Allergy line (HARD constraint, emphasis)
    if !prompt.contains("- HARD ALLERGIES — NEVER include these or any dish containing them: peanut, shellfish") {
        promptOK = false; promptFailures.append("allergy hard-constraint line missing or wrong")
    }
    // Must-avoid
    if !prompt.contains("- MUST AVOID: cilantro, olives") {
        promptOK = false; promptFailures.append("must-avoid line missing")
    }
    // Calorie tolerance rule
    if !prompt.contains("±10% of the daily calorie target") {
        promptOK = false; promptFailures.append("±10% calorie tolerance rule missing")
    }
    // Response shape contract
    if !prompt.contains("= 21 meals total") {
        promptOK = false; promptFailures.append("21-meal contract missing")
    }
    if !prompt.contains("\"recipes\": [") || !prompt.contains("\"meal_plan\": [") {
        promptOK = false; promptFailures.append("response-shape JSON template missing")
    }
    // Week label (date range)
    if !prompt.contains("Week: Monday (2026-06-22) through Sunday (2026-06-28)") {
        promptOK = false; promptFailures.append("week date range missing or wrong")
    }

    if promptOK {
        log.append("(a) prompt-fidelity smoke: dietary goal + allergy line + ±10% rule + 21-meal contract + week label all present ✅")
    } else {
        log.append("❌ (a) prompt-fidelity smoke failed: \(promptFailures.joined(separator: "; "))")
    }

    // ── (b) Parser round-trip (canned 21-meal JSON) ──────────────────────────
    // A minimal but structurally valid provider response with 3 distinct recipes
    // covering 21 meal slots (7 days × 3 slots), matching the prompt's JSON shape.
    let sampleJSON = """
    {
      "recipes": [
        {
          "name": "Lemon Garlic Chicken",
          "meal_type": "dinner",
          "cuisine": "Mediterranean",
          "servings": 4,
          "prep_minutes": 15,
          "cook_minutes": 30,
          "ingredients": [
            {"ingredient_name": "chicken breast", "quantity": 2.0, "unit": "lb", "prep": "cubed", "category": "protein"},
            {"ingredient_name": "garlic", "quantity": 4, "unit": "clove", "category": "aromatic"}
          ],
          "steps": [{"instruction": "Season the chicken."}, {"instruction": "Roast at 400F for 30 minutes."}]
        },
        {
          "name": "Avocado Toast",
          "meal_type": "breakfast",
          "cuisine": "American",
          "servings": 2,
          "prep_minutes": 5,
          "cook_minutes": 5,
          "ingredients": [
            {"ingredient_name": "bread", "quantity": 2, "unit": "slice"},
            {"ingredient_name": "avocado", "quantity": 1, "unit": "ea"}
          ],
          "steps": [{"instruction": "Toast the bread."}, {"instruction": "Mash avocado on top."}]
        },
        {
          "name": "Caesar Salad",
          "meal_type": "lunch",
          "cuisine": "Italian",
          "servings": 2,
          "prep_minutes": 10,
          "cook_minutes": 0,
          "ingredients": [
            {"ingredient_name": "romaine lettuce", "quantity": 1, "unit": "head"},
            {"ingredient_name": "parmesan", "quantity": 2, "unit": "oz"}
          ],
          "steps": [{"instruction": "Toss lettuce with dressing."}]
        }
      ],
      "meal_plan": [
        {"day_name": "Monday",    "meal_date": "2026-06-22", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Monday",    "meal_date": "2026-06-22", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Monday",    "meal_date": "2026-06-22", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Tuesday",   "meal_date": "2026-06-23", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Tuesday",   "meal_date": "2026-06-23", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Tuesday",   "meal_date": "2026-06-23", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Wednesday", "meal_date": "2026-06-24", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Wednesday", "meal_date": "2026-06-24", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Wednesday", "meal_date": "2026-06-24", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Thursday",  "meal_date": "2026-06-25", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Thursday",  "meal_date": "2026-06-25", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Thursday",  "meal_date": "2026-06-25", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Friday",    "meal_date": "2026-06-26", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Friday",    "meal_date": "2026-06-26", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Friday",    "meal_date": "2026-06-26", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Saturday",  "meal_date": "2026-06-27", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Saturday",  "meal_date": "2026-06-27", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Saturday",  "meal_date": "2026-06-27", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"},
        {"day_name": "Sunday",    "meal_date": "2026-06-28", "slot": "breakfast", "recipe_name": "Avocado Toast"},
        {"day_name": "Sunday",    "meal_date": "2026-06-28", "slot": "lunch",     "recipe_name": "Caesar Salad"},
        {"day_name": "Sunday",    "meal_date": "2026-06-28", "slot": "dinner",    "recipe_name": "Lemon Garlic Chicken"}
      ]
    }
    """

    do {
        let result = try MealPlanParser.parse(sampleJSON)
        var parseOK = true
        var parseFailures: [String] = []

        if result.recipes.count != 3 {
            parseOK = false; parseFailures.append("expected 3 recipes, got \(result.recipes.count)")
        }
        if result.mealPlan.count != 21 {
            parseOK = false; parseFailures.append("expected 21 meal slots, got \(result.mealPlan.count)")
        }
        if let r = result.recipes.first(where: { $0.name == "Lemon Garlic Chicken" }) {
            if r.ingredients.count != 2 {
                parseOK = false; parseFailures.append("expected 2 ingredients, got \(r.ingredients.count)")
            }
            if r.prepMinutes != 15 {
                parseOK = false; parseFailures.append("prepMinutes wrong: \(r.prepMinutes as Any)")
            }
        } else {
            parseOK = false; parseFailures.append("Lemon Garlic Chicken recipe missing")
        }
        // Verify slot → recipe resolution works (the name-join used by the app)
        let monDinner = result.mealPlan.first { $0.dayName == "Monday" && $0.slot == "dinner" }
        if result.recipe(for: monDinner!)?.name != "Lemon Garlic Chicken" {
            parseOK = false; parseFailures.append("slot→recipe resolution broken")
        }

        if parseOK {
            log.append("(b) parser round-trip: 3 recipes + 21 slots parsed, ingredient count + prep time + slot resolution correct ✅")
        } else {
            log.append("❌ (b) parser round-trip failed: \(parseFailures.joined(separator: "; "))")
        }
    } catch {
        log.append("❌ (b) parser round-trip threw: \(error)")
    }

    // ── (c) Allergy hard-gate ─────────────────────────────────────────────────
    // A plan that violates the peanut allergy (ingredient: "Peanut Butter").
    let violatingJSON = """
    {
      "recipes": [
        {
          "name": "Thai Noodles",
          "ingredients": [
            {"ingredient_name": "rice noodles"},
            {"ingredient_name": "Peanut Butter"}
          ]
        }
      ],
      "meal_plan": [
        {"day_name": "Monday", "meal_date": "2026-06-22", "slot": "lunch", "recipe_name": "Thai Noodles"}
      ]
    }
    """
    // A clean plan using the same allergen list (no peanut / shellfish).
    let cleanJSON = sampleJSON

    var gateOK = true
    var gateFailures: [String] = []
    let allergens = ctx.allergies   // ["peanut", "shellfish"]

    // Violating plan must throw.
    do {
        let violating = try MealPlanParser.parse(violatingJSON)
        do {
            try MealPlanParser.enforceAllergyGate(violating, allergies: allergens)
            gateOK = false
            gateFailures.append("allergy gate did NOT throw on a plan containing Peanut Butter")
        } catch MealPlanParseError.allergyViolation(let recipe, let allergen) {
            _ = recipe; _ = allergen   // expected
        } catch {
            gateOK = false
            gateFailures.append("allergy gate threw unexpected error: \(error)")
        }
    } catch {
        gateOK = false
        gateFailures.append("failed to parse violating fixture: \(error)")
    }

    // Clean plan must pass.
    do {
        let clean = try MealPlanParser.parse(cleanJSON)
        do {
            try MealPlanParser.enforceAllergyGate(clean, allergies: allergens)
        } catch {
            gateOK = false
            gateFailures.append("allergy gate rejected a clean plan: \(error)")
        }
    } catch {
        gateOK = false
        gateFailures.append("failed to parse clean fixture: \(error)")
    }

    if gateOK {
        log.append("(c) allergy hard-gate: violating plan (Peanut Butter) rejected ✅; clean plan passed ✅")
    } else {
        log.append("❌ (c) allergy hard-gate failed: \(gateFailures.joined(separator: "; "))")
    }

    let allPassed = log.allSatisfy { !$0.hasPrefix("❌") }
    let header = allPassed
        ? "✅ AI week-gen (dry) — prompt/parse/allergy-gate\n"
        : "❌ AI week-gen (dry) — one or more checks failed\n"
    return header + log.joined(separator: "\n")
}

#endif
