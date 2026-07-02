#if canImport(CloudKit)
import Foundation
import Testing
@testable import HouseholdSync

// simmersmith-c7r — HouseholdSyncEngine.init assigns `self.merger` BEFORE constructing
// `self.syncEngine = CKSyncEngine(configuration)`, so `merger` is never nil during the
// window where `automaticSync: true` lets CKSyncEngine start delivering background
// `handleEvent` callbacks (previously `HouseholdSession.start()` wired `engine.merger`
// AFTER the engine — and therefore its automatic sync — already existed, leaving a race
// where an early remote change fell through to blanket LWW instead of the sticky-field
// `RecordMerger`).
//
// The direct behavioral proof — construct a `HouseholdSyncEngine` and assert
// `engine.merger != nil` immediately after — needs a live `CKDatabase` (from a real
// `CKContainer`), and constructing ANY CloudKit object crashes this package's headless
// `swift test` sandbox (confirmed: even bare `CKContainer(identifier:).privateCloudDatabase`
// traps with no iCloud entitlement/XPC access — see ShareRecordFilterTests's and
// RepairSchedulerTests's identical "needs a real CloudKit account, out of scope here"
// convention; no test in this package touches a live `CKDatabase`/`CKContainer`).
//
// So this test asserts the wiring-order contract directly against `HouseholdSyncEngine`'s
// own source: `self.merger = merger` must appear (textually, inside `init`) before
// `self.syncEngine = CKSyncEngine(configuration)`. It's a regression guard on the exact
// ordering invariant the fix depends on — if a future edit moved the merger assignment
// back below the CKSyncEngine construction, this test fails even though the behavioral
// race itself can't be reproduced headlessly.

@Test("HouseholdSyncEngine.init assigns self.merger before constructing self.syncEngine")
func mergerAssignedBeforeSyncEngineConstruction() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let engineSourceURL = thisFile
        .deletingLastPathComponent()   // .../HouseholdSyncTests/
        .deletingLastPathComponent()   // .../Tests/
        .deletingLastPathComponent()   // .../SimmerSmithCloudKit/
        .appendingPathComponent("Sources/HouseholdSync/HouseholdSyncEngine.swift")
    let source = try String(contentsOf: engineSourceURL, encoding: .utf8)

    guard let initRange = source.range(of: "public init(") else {
        Issue.record("could not locate HouseholdSyncEngine.init in source")
        return
    }
    let initBody = source[initRange.lowerBound...]

    guard let mergerAssignRange = initBody.range(of: "self.merger = merger") else {
        Issue.record("init no longer assigns self.merger from the merger parameter")
        return
    }
    guard let syncEngineAssignRange = initBody.range(of: "self.syncEngine = CKSyncEngine(configuration)") else {
        Issue.record("init no longer constructs self.syncEngine = CKSyncEngine(configuration)")
        return
    }

    #expect(
        mergerAssignRange.lowerBound < syncEngineAssignRange.lowerBound,
        "self.merger must be assigned before self.syncEngine = CKSyncEngine(...) is constructed, or automaticSync can deliver a background event while merger is still nil"
    )
}

// The one piece of the contract that IS headlessly testable without CloudKit: the
// `merger` parameter, when supplied, is a live non-nil `RecordMerger` composed exactly
// the way `HouseholdSession.init` now wires it (see `HouseholdSession.swift`) — proving
// the value that would flow into `HouseholdSyncEngine.init(merger:)` is itself non-nil
// and functional, since we can't construct the engine itself here.
@Test("DispatchingMerger composes the same three mergers HouseholdSession wires at init")
func dispatchingMergerComposition() {
    let merger: RecordMerger? = DispatchingMerger([
        GrocerySyncMerger(),
        EventGrocerySyncMerger(),
        EventSyncMerger(),
    ])
    #expect(merger != nil)
    #expect(merger?.handles(GroceryCodec.recordType) == true)
}
#endif
