import Foundation
import Testing
@testable import SimmerSmithKit

// simmersmith-eky (HIGH data-loss) — WeekMealDeletePolicy.toDelete is the fix for
// saveWeekMeals's full-REPLACE delete: a store meal is deleted only if the caller's snapshot
// both knew it (`known`) and dropped it (absent from `desired`). Covers: concurrent-add kept,
// known-and-dropped deleted, edit keeps all, empty known deletes nothing.

@Test("a concurrent add the caller never saw (not in known) is kept even though it's not in desired")
func concurrentAddKept() {
    let existing: Set<String> = ["m1", "m2"]   // m2 was added by another device after the snapshot
    let desired: Set<String> = ["m1"]
    let known: Set<String> = ["m1"]            // caller's snapshot only ever contained m1
    let toDelete = WeekMealDeletePolicy.toDelete(existing: existing, desired: desired, known: known)
    #expect(toDelete.isEmpty)
}

@Test("a meal the caller knew about and dropped is deleted")
func knownAndDroppedDeleted() {
    let existing: Set<String> = ["m1", "m2"]
    let desired: Set<String> = ["m1"]
    let known: Set<String> = ["m1", "m2"]      // caller's snapshot contained both
    let toDelete = WeekMealDeletePolicy.toDelete(existing: existing, desired: desired, known: known)
    #expect(toDelete == ["m2"])
}

@Test("editing meals without removing any keeps everything")
func editKeepsAll() {
    let existing: Set<String> = ["m1", "m2"]
    let desired: Set<String> = ["m1", "m2"]    // desired is a superset of (equal to) known
    let known: Set<String> = ["m1", "m2"]
    let toDelete = WeekMealDeletePolicy.toDelete(existing: existing, desired: desired, known: known)
    #expect(toDelete.isEmpty)
}

@Test("an empty known set (e.g. a freshly created week) never deletes anything")
func emptyKnownDeletesNothing() {
    let existing: Set<String> = ["m1", "m2"]
    let desired: Set<String> = []
    let known: Set<String> = []
    let toDelete = WeekMealDeletePolicy.toDelete(existing: existing, desired: desired, known: known)
    #expect(toDelete.isEmpty)
}
