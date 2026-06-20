#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge
import HouseholdRecords
import HouseholdSync
import SimmerSmithKit

// NOTE: GroceryMerge is imported here (unlike WeekRepository, which avoids it).
// In WeekRepository, the GroceryMerge type is reached via type inference from
// GroceryCodec.decode(record). Here we need to *write* GroceryMerge items, which
// requires calling GroceryCodec.makeRecord. We avoid bare `GroceryItem` in any
// function signature — we use `GroceryMerge.GroceryItem` for the merge type and
// rely on type inference from `week.groceryItems` for the domain type. The helper
// function that converts the domain → merge grocery item is written as a generic to
// avoid a bare `GroceryItem` parameter type (which would be ambiguous between modules).

// SP-C Task 5 — one-time Fly→CloudKit migration of weeks + grocery.
//
// Mirrors RecipeMigrationLoader (Data/RecipeMigrationLoader.swift) in structure,
// receipt-gate pattern, crash-safety, and write ordering. Key differences:
//
//  1. ONE-SHOT FLY AUTH — everyday Fly auth was dropped in the Identity slice
//     (RootView now gates on CloudKit, not the Fly JWT). This migration requires
//     a Fly JWT to call /api/weeks. It obtains one via a user-initiated Apple
//     sign-in (the dormant `AppState.signInWithApple(identityToken:)` path), then
//     discards the token immediately after migration — the token is NOT persisted
//     beyond the migration run, and no everyday flow is gated on it.
//
//  2. Two-level fetch — the /api/weeks list returns [WeekSummary] (no meals,
//     no grocery); a per-week /api/weeks/:id detail fetch returns the full
//     WeekSnapshot. We iterate the summaries and fetch each detail individually
//     (bounded by weekFetchConcurrency). The Fly /api/weeks endpoint is paginated
//     via `limit`; we fetch with limit=100 to capture all user weeks in one pass.
//
//  3. GroceryItem encoding — the domain `GroceryItem` (SimmerSmithKit) must be
//     converted to the merge `GroceryItem` (GroceryMerge) before GroceryCodec
//     can write it as a CKRecord. The conversion is done inline (not via
//     migrateGroceryItem, which expects a snake_case row dict, and not via a
//     helper with a bare `GroceryItem` parameter — see NOTE above). Logical
//     clocks that have no equivalent in the Fly JSON default to 0; the first
//     real device edit carries a higher clock and wins correctly.
//
//  4. Week + meal records via WeekRecordMapper; sides via the same mapper;
//     grocery records via GroceryCodec.makeRecord. Order: week → meals → sides →
//     grocery → receipt (receipt always last for crash-safety).
//
//  5. Receipt: scope "weeks" → CKRecord named "migrated:weeks". The gate checks
//     the local store (same as the recipe gate), so the receipt synced from
//     another device short-circuits the migration on subsequent devices too.

private let weekMigrationScope = "weeks"
private let weekFetchConcurrency = 4

// MARK: - Migration entry point

/// Pull all weeks (+ meals, sides, grocery) from Fly and write them into the
/// household CloudKit zone. No-op if the "weeks" migration receipt is already
/// present. The caller (AppState.importWeeksFromFly) is responsible for ensuring
/// the apiClient's auth token is set (via the one-shot Apple sign-in) before
/// calling this function.
///
/// - Parameters:
///   - session: the live CloudKit household session (zone provisioned + first
///     fetch done).
///   - apiClient: the Fly API client with a valid auth token already set.
@MainActor
func migrateWeeksIfNeeded(
    session: HouseholdSession,
    apiClient: SimmerSmithAPIClient
) async {
    // Gate: skip if the receipt is already present (migrated on this or another device).
    let receiptID = CKRecord.ID(
        recordName: HouseholdMigrationRunner.receiptRecordName(scope: weekMigrationScope),
        zoneID: session.zoneID
    )
    guard session.store.record(for: receiptID) == nil else { return }

    // Fetch the list of all user weeks from Fly. Use limit=100 to capture
    // users with many historical weeks in one round-trip. A failure here aborts
    // without stamping the receipt so the next trigger retries.
    let summaries: [WeekSummary]
    do {
        summaries = try await apiClient.fetchWeeks(limit: 100)
    } catch {
        // Network unavailable or Fly token invalid — leave receipt unstamped for retry.
        return
    }

    guard !summaries.isEmpty else {
        // No weeks to migrate — stamp the receipt and return cleanly so the
        // next launch doesn't retry a no-op.
        let receipt = CKRecord(recordType: HouseholdMigrationRunner.receiptType, recordID: receiptID)
        receipt["scope"] = weekMigrationScope as CKRecordValue
        session.engine.save(receipt)
        try? await session.engine.sendUntilDrained()
        return
    }

    // Fetch per-week detail (meals + grocery) in parallel, bounded by concurrency.
    // The detail endpoint returns the full WeekSnapshot including meals and groceryItems.
    let weekSnapshots: [WeekSnapshot] = await withTaskGroup(
        of: WeekSnapshot?.self
    ) { group in
        var inFlight = 0
        var iterator = summaries.makeIterator()
        var results: [WeekSnapshot] = []

        // Seed initial batch.
        while inFlight < weekFetchConcurrency, let summary = iterator.next() {
            let weekID = summary.weekId
            group.addTask {
                try? await apiClient.fetchWeek(weekID: weekID)
            }
            inFlight += 1
        }

        // Drain group; replenish from iterator as slots free up.
        for await result in group {
            inFlight -= 1
            if let snapshot = result {
                results.append(snapshot)
            }
            if let next = iterator.next() {
                let weekID = next.weekId
                group.addTask {
                    try? await apiClient.fetchWeek(weekID: weekID)
                }
                inFlight += 1
            }
        }
        return results
    }

    // Write each week: primary .week record → .weekMeal children → .weekMealSide
    // grandchildren → GroceryItem records. Order within a week is write-before-read
    // safe (engine upserts are PK-preserving; a crash at any point leaves the receipt
    // unstamped so the retry is fully idempotent).
    for week in weekSnapshots {
        let mapped = WeekRecordMapper.records(from: week)

        // Write the .week record.
        session.engine.save(HouseholdRecordCodec.encode(mapped.week, zoneID: session.zoneID))

        // Write .weekMeal children.
        for mealValue in mapped.meals {
            session.engine.save(HouseholdRecordCodec.encode(mealValue, zoneID: session.zoneID))
        }

        // Write .weekMealSide grandchildren.
        for sideValue in mapped.sides {
            session.engine.save(HouseholdRecordCodec.encode(sideValue, zoneID: session.zoneID))
        }

        // Write GroceryItem records via GroceryCodec.
        // Convert each domain GroceryItem (inferred from week.groceryItems) to a
        // GroceryMerge.GroceryItem, then write via GroceryCodec.makeRecord. The
        // conversion is done inline (no helper with a bare GroceryItem parameter)
        // to sidestep the module-name collision (see NOTE at top of file).
        // Logical clocks (checkedAt, createdAt, modifiedAt) default to 0 — the
        // first real device edit will carry a higher clock and win correctly.
        let weekID = week.weekId
        for domainItem in week.groceryItems {
            let mergeItem = GroceryMerge.GroceryItem(
                recordName: domainItem.groceryItemId,
                weekID: weekID,
                baseIngredientID: domainItem.baseIngredientId,
                ingredientVariationID: domainItem.ingredientVariationId,
                resolutionStatus: domainItem.resolutionStatus,
                unit: domainItem.unit,
                quantityText: domainItem.quantityText,
                normalizedName: domainItem.normalizedName,
                ingredientName: domainItem.ingredientName,
                category: domainItem.category,
                totalQuantity: domainItem.totalQuantity,
                notes: domainItem.notes,
                sourceMeals: domainItem.sourceMeals,
                reviewFlag: domainItem.reviewFlag,
                storeLabel: domainItem.storeLabel,
                isUserAdded: domainItem.isUserAdded,
                isUserRemoved: domainItem.isUserRemoved,
                quantityOverride: domainItem.quantityOverride,
                unitOverride: domainItem.unitOverride,
                notesOverride: domainItem.notesOverride,
                check: CheckState(
                    isChecked: domainItem.isChecked,
                    at: 0,  // no clock in the Fly payload; defaults to 0
                    by: domainItem.checkedByUserId
                ),
                eventQuantity: domainItem.eventQuantity,
                createdAt: 0,   // no clock in the Fly payload
                modifiedAt: 0   // no clock in the Fly payload
            )
            let ckRecord = GroceryCodec.makeRecord(mergeItem, zoneID: session.zoneID)
            session.engine.save(ckRecord)
        }
    }

    // Stamp the receipt LAST — mirrors the crash-safety invariant in
    // HouseholdMigrationRunner.migrate(): a crash before this leaves no receipt,
    // so the retry re-runs (the engine's PK-preserving upserts make it idempotent).
    let receipt = CKRecord(recordType: HouseholdMigrationRunner.receiptType, recordID: receiptID)
    receipt["scope"] = weekMigrationScope as CKRecordValue
    session.engine.save(receipt)

    // Drain: push all saves to CloudKit. The engine's automaticSync also fires in
    // the background, but an explicit drain ensures the write reaches the server
    // before the first WeekRepository.reload() reads the store.
    try? await session.engine.sendUntilDrained()
}
#endif
