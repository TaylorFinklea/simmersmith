#if canImport(CloudKit)
import Testing
import GroceryMerge
@testable import HouseholdSync

@Test("grocery dedupe adapter writes only changed keepers, tombstones, and repointed links")
func groceryDedupeAdapterWritesExactRepairSet() {
    let result = ConflictRepair.dedupeGrocery(items: [
        GroceryItem(
            recordName: "G_single", unit: "cup", normalizedName: "tomato",
            sourceMeals: "meal:single", createdAt: 1),
        GroceryItem(
            recordName: "G_changed_keep", unit: "cup", normalizedName: "rice",
            totalQuantity: 2, sourceMeals: "meal:a", createdAt: 1),
        GroceryItem(
            recordName: "G_changed_dead", unit: "cup", normalizedName: "rice",
            totalQuantity: 3, sourceMeals: "meal:b", createdAt: 2),
        GroceryItem(
            recordName: "G_static_keep", unit: "", normalizedName: "salt",
            isUserAdded: true, createdAt: 1),
        GroceryItem(
            recordName: "G_static_dead", unit: "", normalizedName: "salt",
            isUserAdded: true, createdAt: 2),
    ], eventLinks: [
        EventGroceryItem(
            recordName: "E_static", mergedIntoGroceryItemID: "G_static_dead",
            eventQuantity: 1, modifiedAt: 1),
    ])
    var groceryWrites: [GroceryItem] = []
    var eventWrites: [EventGroceryItem] = []

    EventMergeAdapter.applyDedupeResult(
        result,
        saveGrocery: { groceryWrites.append($0) },
        saveEventRow: { eventWrites.append($0) })

    #expect(result.keepers.map(\.recordName) == ["G_changed_keep", "G_single", "G_static_keep"])
    #expect(groceryWrites.map(\.recordName)
        == ["G_changed_keep", "G_changed_dead", "G_static_dead"])
    #expect(eventWrites.map(\.recordName) == ["E_static"])
    #expect(eventWrites.first?.mergedIntoGroceryItemID == "G_static_keep")
}

@MainActor
private final class RepairWriteLoopHarness {
    var scheduler: RepairScheduler?
    private(set) var passCount = 0
    private(set) var writeCount = 0
    private var items: [String: GroceryItem]

    init(items: [GroceryItem]) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.recordName, $0) })
    }

    func runPass() {
        passCount += 1
        let result = ConflictRepair.dedupeGrocery(items: Array(items.values), eventLinks: [])
        var wrote = false
        EventMergeAdapter.applyDedupeResult(
            result,
            saveGrocery: {
                items[$0.recordName] = $0
                writeCount += 1
                wrote = true
            },
            saveEventRow: { _ in })
        if wrote {
            scheduler?.signal()
        }
    }
}

@Test("a repair write signal converges after one follow-up pass")
@MainActor
func groceryDedupeRepairDoesNotSignalItselfForever() async {
    let harness = RepairWriteLoopHarness(items: [
        GroceryItem(
            recordName: "G_keep", unit: "cup", normalizedName: "tomato",
            totalQuantity: 2, sourceMeals: "meal:a", createdAt: 1),
        GroceryItem(
            recordName: "G_dead", unit: "cup", normalizedName: "tomato",
            totalQuantity: 3, sourceMeals: "meal:b", createdAt: 2),
    ])
    let scheduler = RepairScheduler(
        ownsZone: false,
        debounceNanoseconds: 1_000_000,
        passes: .init(
            nonDestructive: { harness.runPass() },
            destructive: {}))
    harness.scheduler = scheduler
    scheduler.activate()

    scheduler.signal()
    try? await Task.sleep(nanoseconds: 100_000_000)
    await scheduler.quiesce()

    #expect(harness.passCount == 2)
    #expect(harness.writeCount == 2)
}
#endif
