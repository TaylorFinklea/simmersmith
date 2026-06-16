import Foundation
import SwiftData
import Testing
@testable import SimmerSmithKit

// SP-A Phase 1 — invariant tests for the per-user PRIVATE plane store. Run against an
// in-memory store (cloudKitDatabase: .none) so they're headless + fast; the on-device
// CloudKit round-trip is verified separately via the DEBUG CloudKit-checks panel.

@MainActor
private func makeStore() throws -> PrivatePlaneStore {
    let container = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
    return PrivatePlaneStore(context: container.mainContext)
}

@Test @MainActor
func profileSettingUpsertIsSingletonPerKey() throws {
    let store = try makeStore()
    try store.upsertProfileSetting(key: "unit_system", value: "us")
    try store.upsertProfileSetting(key: "unit_system", value: "metric")
    try store.save()

    let rows = try store.context.fetch(
        FetchDescriptor<PrivateProfileSetting>(predicate: #Predicate { $0.recordKey == "unit_system" })
    )
    #expect(rows.count == 1)
    #expect(rows.first?.value == "metric")
}

@Test @MainActor
func dietaryGoalIsSingleton() throws {
    let store = try makeStore()
    try store.upsertDietaryGoal(goalType: "lose", dailyCalories: 2000, proteinG: 150,
                                carbsG: 200, fatG: 60, fiberG: 30, notes: "first")
    try store.upsertDietaryGoal(goalType: "maintain", dailyCalories: 2200, proteinG: 160,
                                carbsG: 220, fatG: 70, fiberG: 32, notes: "second")
    try store.save()

    let goals = try store.context.fetch(FetchDescriptor<PrivateDietaryGoal>())
    #expect(goals.count == 1)
    #expect(goals.first?.goalType == "maintain")
    #expect(goals.first?.dailyCalories == 2200)
}

@Test @MainActor
func preferenceSignalDeterministicKeyDedupes() throws {
    let store = try makeStore()
    try store.upsertPreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 0.8, active: true)
    try store.upsertPreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 0.9, active: false)
    try store.save()

    let rows = try store.context.fetch(
        FetchDescriptor<PrivatePreferenceSignal>(predicate: #Predicate { $0.recordKey == "cuisine:thai" })
    )
    #expect(rows.count == 1)
    #expect(rows.first?.score == 0.9)
    #expect(rows.first?.active == false)
}

@Test @MainActor
func ingredientPreferenceUpsertByID() throws {
    let store = try makeStore()
    try store.upsertIngredientPreference(preferenceID: "pref-1", baseIngredientID: "ing-1",
                                         choiceMode: "preferred", rank: 1, active: true, brand: "Acme", variation: "organic")
    try store.upsertIngredientPreference(preferenceID: "pref-1", baseIngredientID: "ing-1",
                                         choiceMode: "preferred", rank: 2, active: true, brand: "Acme", variation: "organic")
    try store.save()

    let rows = try store.context.fetch(
        FetchDescriptor<PrivateIngredientPreference>(predicate: #Predicate { $0.recordKey == "pref-1" })
    )
    #expect(rows.count == 1)
    #expect(rows.first?.rank == 2)
}

@Test @MainActor
func assistantTranscriptOrdersByCreatedAt() throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let thread = try store.upsertAssistantThread(threadID: "t1", title: "Plan", createdAt: base, updatedAt: base)
    // Insert out of order; query must return createdAt-ascending.
    try store.upsertAssistantMessage(messageID: "m2", thread: thread, role: "assistant", content: "second", createdAt: base.addingTimeInterval(1))
    try store.upsertAssistantMessage(messageID: "m1", thread: thread, role: "user", content: "first", createdAt: base)
    try store.save()

    let ordered = try store.messages(forThreadID: "t1").map(\.content)
    #expect(ordered == ["first", "second"])
}

@Test @MainActor
func deletingThreadCascadesToMessages() throws {
    let store = try makeStore()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let thread = try store.upsertAssistantThread(threadID: "t1", title: "Plan", createdAt: base, updatedAt: base)
    try store.upsertAssistantMessage(messageID: "m1", thread: thread, role: "user", content: "hi", createdAt: base)
    try store.save()

    store.context.delete(thread)
    try store.save()

    #expect(try store.messages(forThreadID: "t1").isEmpty)
    let allMessages = try store.context.fetch(FetchDescriptor<PrivateAssistantMessage>())
    #expect(allMessages.isEmpty)
}

@Test @MainActor
func migrationScopeClaimsOnce() throws {
    let store = try makeStore()
    #expect(try store.claimMigrationScope("households") == true)
    #expect(try store.claimMigrationScope("households") == false)
    #expect(try store.claimMigrationScope("recipes") == true)
}
