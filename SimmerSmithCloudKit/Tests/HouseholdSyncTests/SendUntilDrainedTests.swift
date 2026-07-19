#if canImport(CloudKit)
import Testing
@testable import HouseholdSync

// A live CKSyncEngine/CKContainer traps in the package sandbox. This pure
// completion seam pins the post-loop invariant that the live drain enforces.

@Test("an exhausted send drain fails while record changes remain pending")
func exhaustedDrainWithPendingRecordsThrowsRetryableFailure() {
    do {
        try HouseholdSyncEngine.requireDrained(
            pendingRecordChangeCount: 3,
            maxPasses: 8
        )
        Issue.record("exhausted pending drain returned success")
    } catch let error as HouseholdSyncEngine.DrainError {
        #expect(error == .exhaustedPendingRecordChanges(pendingCount: 3, maxPasses: 8))
    } catch {
        Issue.record("exhausted pending drain threw unexpected error: \(error)")
    }
}

@Test("zero drain passes still succeeds for an already-empty queue")
func zeroPassDrainSucceedsWhenNoRecordsArePending() throws {
    try HouseholdSyncEngine.requireDrained(
        pendingRecordChangeCount: 0,
        maxPasses: 0
    )
}

@Test("zero drain passes fail rather than falsely completing pending work")
func zeroPassDrainFailsWhenRecordsArePending() {
    #expect(throws: HouseholdSyncEngine.DrainError.self) {
        try HouseholdSyncEngine.requireDrained(
            pendingRecordChangeCount: 1,
            maxPasses: 0
        )
    }
}
#endif
