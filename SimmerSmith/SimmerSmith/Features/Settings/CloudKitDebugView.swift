#if DEBUG
import SwiftUI
import SwiftData
import CloudKitProvisioning
import CoexistenceSpike
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
            } header: {
                SmithSectionHeader("cloudkit checks")
            } footer: {
                Text("Phase 0 proves zone + record write/read. Phase 0.5 proves NSPCKC + a CKSyncEngine-style stack coexist. Phase 1 loads the CloudKit-backed private store + checks upsert dedupe, singletons, transcript ordering, and the migration sentinel.")
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
#endif
