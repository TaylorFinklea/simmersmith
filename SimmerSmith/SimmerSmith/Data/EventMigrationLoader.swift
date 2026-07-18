#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge
import HouseholdRecords
import HouseholdSync
import OSLog
import SimmerSmithKit

// SP-C Task 5 — one-time Fly→CloudKit migration of events + guests + event-grocery.
//
// Mirrors WeekMigrationLoader (Data/WeekMigrationLoader.swift) in structure,
// receipt-gate pattern, crash-safety, and write ordering. Key differences from
// the weeks migration:
//
//  1. TWO-LEVEL FETCH (same as weeks):
//     /api/events returns [EventSummary] (no meals, no attendees, no grocery);
//     /api/events/:id returns a full Event aggregate. We fetch summaries first,
//     then detail per-event in parallel (bounded by eventFetchConcurrency).
//     Guests are fetched in a single /api/guests call (includeInactive: true so
//     the roster is complete even if some guests were deactivated on Fly).
//
//  2. WRITE ORDER (crash-safe):
//     (a) Guests (.guest records) FIRST — attendee refs point to guest records,
//         so guests must exist before attendees are written.
//     (b) For each event: .event record → .eventMeal children → .eventMealIngredient
//         grandchildren → .eventAttendee children → EventGroceryItem records.
//     (c) Receipt LAST — a crash before this leaves no receipt, so the retry
//         re-runs (the engine's PK-preserving upserts make it idempotent).
//
//  3. EVENT-GROCERY ENCODING:
//     The domain `EventGroceryItem` (SimmerSmithKit) must be converted to the merge
//     `EventGroceryItem` (GroceryMerge) before EventGroceryCodec can write it as a
//     CKRecord. Logical clocks (modifiedAt) default to 0; the first real device edit
//     carries a higher clock and wins correctly. Record names follow the
//     `<eventID>_eg_<n>` prefix convention used by EventRepository so the live
//     event-grocery scan can find migrated rows by prefix.
//
//  4. RECEIPT: scope "events" → CKRecord named "migrated:events". The gate checks
//     the local store (same as the weeks gate), so the receipt synced from another
//     device short-circuits the migration on subsequent devices too.
//
//  5. ONE-SHOT FLY AUTH: same as weeks — the caller (AppState.importEventsFromFly)
//     is responsible for ensuring the apiClient's auth token is set before calling
//     this function. The token is NOT persisted beyond the migration run.

private let eventMigrationScope = "events"
private let eventFetchConcurrency = 4
private let log = Logger(subsystem: "app.simmersmith.cloud", category: "EventMigrationLoader")

/// True when every expected event produced a detail fetch — the completeness check the
/// RECEIPT-BLOCKING RULE (in `migrateEventsIfNeeded` below) gates the receipt stamp on.
/// Internal (not private) so the app-target test can pin the contract.
func eventMigrationIsComplete(expectedCount: Int, fetchedCount: Int) -> Bool {
    expectedCount == fetchedCount
}

// MARK: - Migration entry point

/// Pull all events (+ meals, ingredients, attendees, event-grocery) and guests from Fly
/// and write them into the household CloudKit zone. No-op if the "events" migration
/// receipt is already present. The caller (AppState.importEventsFromFly) is responsible
/// for ensuring the apiClient's auth token is set (via the one-shot Apple sign-in).
///
/// - Parameters:
///   - session: the live CloudKit household session (zone provisioned + first fetch done).
///   - apiClient: the Fly API client with a valid auth token already set.
@MainActor
func migrateEventsIfNeeded(
    session: HouseholdSession,
    apiClient: SimmerSmithAPIClient
) async {
    guard CachedHouseholdSystemOperationPolicy.allows(
        .migration,
        isCachedBootstrap: session.isCachedBootstrap) else { return }
    // Gate: skip if the receipt is already present (migrated on this or another device).
    let receiptID = CKRecord.ID(
        recordName: HouseholdMigrationRunner.receiptRecordName(scope: eventMigrationScope),
        zoneID: session.zoneID
    )
    guard session.store.record(for: receiptID) == nil else { return }

    // Fetch the guest roster first. includeInactive: true so deactivated guests still
    // arrive (their .guest records in CloudKit let attendee refs resolve correctly).
    // A failure here aborts without stamping the receipt so the next trigger retries.
    let guests: [Guest]
    do {
        guests = try await apiClient.fetchGuests(includeInactive: true)
    } catch {
        // Network unavailable or Fly token invalid — leave receipt unstamped for retry.
        return
    }

    // Fetch the list of all user event summaries from Fly. A failure here likewise
    // aborts without stamping the receipt.
    let summaries: [EventSummary]
    do {
        summaries = try await apiClient.fetchEvents()
    } catch {
        return
    }

    // If both collections are empty, stamp the receipt and return cleanly so the
    // next launch doesn't retry a no-op.
    guard !guests.isEmpty || !summaries.isEmpty else {
        let receipt = CKRecord(recordType: HouseholdMigrationRunner.receiptType, recordID: receiptID)
        receipt["scope"] = eventMigrationScope as CKRecordValue
        session.engine.save(receipt)
        try? await session.engine.sendUntilDrained()
        return
    }

    // Write guests FIRST — attendee records ref guest records, so the guest records
    // must already exist in the zone when attendees are written.
    for guest in guests {
        let guestValue = EventRecordMapper.record(from: guest)
        session.engine.save(HouseholdRecordCodec.encode(guestValue, zoneID: session.zoneID))
    }

    // Fetch per-event detail (meals + ingredients + attendees + grocery) in parallel,
    // bounded by eventFetchConcurrency. The detail endpoint returns the full Event
    // aggregate (meals, attendees with guestId, groceryItems).
    // NOTE: `DomainEvent` alias (= SimmerSmithKit.Event) is used to disambiguate from
    // GroceryMerge.Event — same technique as EventRepository.swift.
    let fullEvents: [DomainEvent] = await withTaskGroup(of: DomainEvent?.self) { group in
        var inFlight = 0
        var iterator = summaries.makeIterator()
        var results: [DomainEvent] = []

        // Seed initial batch.
        while inFlight < eventFetchConcurrency, let summary = iterator.next() {
            let eventID = summary.eventId
            group.addTask {
                try? await apiClient.fetchEvent(eventID: eventID)
            }
            inFlight += 1
        }

        // Drain; replenish from iterator as slots free up.
        for await result in group {
            inFlight -= 1
            if let event = result {
                results.append(event)
            }
            if let next = iterator.next() {
                let eventID = next.eventId
                group.addTask {
                    try? await apiClient.fetchEvent(eventID: eventID)
                }
                inFlight += 1
            }
        }
        return results
    }

    // Write each event and its children. Order within an event:
    // .event → .eventMeal → .eventMealIngredient → .eventAttendee → EventGroceryItem.
    // This is write-before-read safe: the engine's PK-preserving upserts mean a crash
    // at any point leaves the receipt unstamped, so the retry is fully idempotent.
    for event in fullEvents {
        let mapped = EventRecordMapper.records(from: event)

        // Write the .event root record.
        session.engine.save(HouseholdRecordCodec.encode(mapped.event, zoneID: session.zoneID))

        // Write .eventMeal children.
        for mealValue in mapped.meals {
            session.engine.save(HouseholdRecordCodec.encode(mealValue, zoneID: session.zoneID))
        }

        // Write .eventMealIngredient grandchildren.
        for ingredientValue in mapped.ingredients {
            session.engine.save(HouseholdRecordCodec.encode(ingredientValue, zoneID: session.zoneID))
        }

        // Write .eventAttendee children (det-keyed <eventID>_<guestID>).
        for attendeeValue in mapped.attendees {
            session.engine.save(HouseholdRecordCodec.encode(attendeeValue, zoneID: session.zoneID))
        }

        // Write EventGroceryItem records via EventGroceryCodec.
        // Domain EventGroceryItem (SimmerSmithKit) → merge EventGroceryItem (GroceryMerge)
        // via migrateEventGroceryItem (MigrationTransforms). Record names follow the
        // `<eventID>_eg_<n>` prefix convention so EventRepository's prefix-scan can find
        // migrated rows without any schema changes.
        // sourceMeals in the domain model is [String]; the migration transform expects a
        // JSON-array string (the server stores it that way). Encode it inline.
        let eventID = event.eventId
        let prefix = "\(eventID)_eg_"
        for (index, domainItem) in event.groceryItems.enumerated() {
            let sourceMealsJSON = (try? String(data: JSONEncoder().encode(domainItem.sourceMeals), encoding: .utf8)) ?? "[]"
            // Compute normalized_name the SAME way EventGroceryGenerator does
            // (GroceryNormalize.name on the ingredient name) so migrated event rows match the
            // week's rows by MergeKey when there's no baseIngredientID. An empty normalized_name
            // would spawn spurious event-only week rows instead of contributing eventQuantity.
            let normalizedName = GroceryNormalize.name(domainItem.ingredientName)
            let row: [String: Any] = [
                "id": domainItem.groceryItemId,
                "ingredient_name": domainItem.ingredientName,
                "normalized_name": normalizedName,
                "unit": domainItem.unit,
                "quantity_text": domainItem.quantityText,
                "category": domainItem.category,
                "source_meals": sourceMealsJSON,
                "notes": domainItem.notes,
                "review_flag": domainItem.reviewFlag,
                "resolution_status": "unresolved",
                "base_ingredient_id": domainItem.baseIngredientId as Any,
                "ingredient_variation_id": domainItem.ingredientVariationId as Any,
                "total_quantity": domainItem.totalQuantity as Any,
                "merged_into_week_id": domainItem.mergedIntoWeekId as Any,
                "merged_into_grocery_item_id": domainItem.mergedIntoGroceryItemId as Any,
                "updated_at_clock": 0,
            ]
            guard var mergeItem = migrateEventGroceryItem(row) else { continue }

            // Rewrite the record name to the `<eventID>_eg_<n>` prefix convention used
            // by EventRepository. The Fly row id is replaced with the prefix-keyed name
            // so the live scan in EventRepository finds exactly this event's rows.
            let prefixedName = "\(prefix)\(index)"
            mergeItem = GroceryMerge.EventGroceryItem(
                recordName: prefixedName,
                mergedIntoGroceryItemID: mergeItem.mergedIntoGroceryItemID,
                mergedIntoWeekID: mergeItem.mergedIntoWeekID,
                eventQuantity: mergeItem.eventQuantity,
                baseIngredientID: mergeItem.baseIngredientID,
                ingredientVariationID: mergeItem.ingredientVariationID,
                ingredientName: mergeItem.ingredientName,
                normalizedName: mergeItem.normalizedName,
                unit: mergeItem.unit,
                quantityText: mergeItem.quantityText,
                category: mergeItem.category,
                sourceMeals: mergeItem.sourceMeals,
                notes: mergeItem.notes,
                reviewFlag: mergeItem.reviewFlag,
                resolutionStatus: mergeItem.resolutionStatus,
                modifiedAt: 0   // no clock in the Fly payload; first real device edit wins
            )
            let ckRecord = EventGroceryCodec.makeRecord(mergeItem, zoneID: session.zoneID)
            session.engine.save(ckRecord)
        }
    }

    // RECEIPT-BLOCKING RULE (mirrors RecipeMigrationLoader / WeekMigrationLoader): any
    // event whose detail fetch failed above is silently missing from fullEvents (the
    // task group uses try?). Compare the fetched count against the expected count from
    // summaries; on any drop, everything fetched is still saved (loop above already
    // ran) and drained, but the receipt is withheld so the next launch retries the
    // whole migration (idempotent — the engine's PK-preserving upserts dedupe re-writes).
    let droppedEvents = summaries.count - fullEvents.count
    guard eventMigrationIsComplete(expectedCount: summaries.count, fetchedCount: fullEvents.count) else {
        log.error("event migration dropped \(droppedEvents, privacy: .public) of \(summaries.count, privacy: .public) events; receipt withheld for retry")
        try? await session.engine.sendUntilDrained()
        return
    }

    // Stamp the receipt LAST — mirrors the crash-safety invariant in WeekMigrationLoader
    // and HouseholdMigrationRunner.migrate(): a crash before this leaves no receipt,
    // so the retry re-runs (idempotent via PK-preserving upserts).
    let receipt = CKRecord(recordType: HouseholdMigrationRunner.receiptType, recordID: receiptID)
    receipt["scope"] = eventMigrationScope as CKRecordValue
    session.engine.save(receipt)

    // Drain: push all saves to CloudKit. An explicit drain ensures the write reaches the
    // server before the first EventRepository.reload() reads the store.
    try? await session.engine.sendUntilDrained()
}
#endif
