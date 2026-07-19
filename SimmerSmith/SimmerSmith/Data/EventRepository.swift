#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync
import GroceryMerge

// NAME-COLLISION NOTE: this file genuinely NAMES many GroceryMerge value types (EventMergeEngine,
// EventGroceryMeal, GroceryIngredientLine, GroceryMerge.Week/Event/GroceryItem/EventGroceryItem,
// SyncClock), so unlike WeekRepository — which reaches the merge GroceryItem purely by inference —
// it MUST `import GroceryMerge`. That makes bare `Event` / `EventGroceryItem` / `Week` /
// `GroceryItem` ambiguous, and the DOMAIN ones can't be module-qualified because the module name
// `SimmerSmithKit` is shadowed by an enum of the same name. Resolution: every GroceryMerge type is
// written `GroceryMerge.X`; the domain aggregate is referenced through the `DomainEvent` alias
// declared in EventRepository+DomainTypes.swift (a sibling file that does NOT import GroceryMerge,
// so `Event` there resolves unambiguously to the domain type).

// SP-C Task 3 — EventRepository: event + meal + ingredient + attendee CRUD, event-grocery
// regen, and the event↔week merge/unmerge — all backed by the CloudKit household store.
//
// Mirrors WeekRepository/GroceryRepository (the just-built slice). Reads reassemble a full
// `Event` aggregate from its `.event` record + `.eventMeal` children (+ their
// `.eventMealIngredient` grandchildren) + `.eventAttendee` children (with each attendee's
// `.guest` resolved from the store); writes decompose an Event back into those records,
// child-diffing meals/ingredients/attendees the same way WeekRepository diffs meals/sides
// (save changed + new, explicit per-record delete for removed — NOT cascade, which is only
// for a whole-event delete).
//
// THREE load-bearing seams beyond plain CRUD:
//
//   - EVENT-GROCERY REGEN (`refreshEventGrocery`): aggregates the event's meals into a fresh
//     `[EventGroceryItem]` (merge type) via the T2 EventGroceryGenerator port, then wipe-and-
//     rebuilds this event's EventGroceryItem records. Unlike the WEEK regen, the event regen
//     carries NO sticky state (the server hard-deletes every prior event row and recreates the
//     set — EventGroceryGenerator.swift). To make "this event's rows" a cheap, deterministic
//     scan that survives the wipe, fresh row record names are minted with an `<eventID>_eg_`
//     prefix (a pure naming convention — the merge `EventGroceryItem`/codec carry no eventID
//     field, and the spec forbids new manifest types). The unmerge-before-wipe / re-apply-policy
//     dance the server does around regen is wired HERE (the generator only emits fresh rows).
//
//   - MERGE / UNMERGE (`mergeEventGroceryIntoWeek` / `unmergeEventGroceryFromWeek`): delegate to
//     the built `EventMergeAdapter` (SP-A) — never reimplemented here. The adapter runs the pure
//     `EventMergeEngine`, which HARD-deletes event-only week rows on unmerge but PRESERVES week
//     rows carrying user investment (override / check / user-added). This wiring must not bypass
//     that — so unmerge reads the event's current rows, hands them to the adapter, and lets it
//     decide; it never deletes week rows itself.
//
//   - AUTO-MERGE POLICY (`toggleEventAutoMerge` + meal/date changes → `applyAutoMergePolicy`):
//     re-resolves the event's target week (linkedWeekID else the eventDate-covering week) and
//     merges/unmerges via the engine's policy, applying the resulting mutations through the
//     adapter's merge/unmerge.
//
// Two `Event` types coexist: the rich domain `Event` (this repo's read/write
// currency) and the thin `GroceryMerge.Event` value type the merge engine/adapter consume. The
// bridge (`mergeEvent(forId:)`) builds the latter from the `.event` record so the engine sees the
// authoritative manuallyMerged / linkedWeekID / autoMergeGrocery / eventDate fields.
//
// Headless note (mirrors WeekRepository/RecipeRepository): the child-diff + merge wiring live at
// the engine.save/delete call site (not a pure value transform), and HouseholdSyncEngine can't be
// instantiated without iCloud, so verification is on-device (spec §6). The pure pieces it leans on
// (EventRecordMapper round-trip, EventGroceryGenerator fidelity, EventMergeEngine) are headlessly
// tested in their own targets.

@MainActor
@Observable
final class EventRepository {

    // MARK: - Observable state

    /// Full reassembled event aggregates, newest-event-first (eventDate desc, then updatedAt desc).
    private(set) var events: [DomainEvent] = []

    /// Set when `sendUntilDrained()` fails on any write path (mirrors RecipeRepository).
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession
    private let guests: GuestRepository

    /// Monotonic logical clock for fresh event-grocery rows (EventGroceryItem stores its clock as
    /// Int). Seeded from the wall clock so it advances across launches; bumped per regen.
    private var clock: SyncClock

    // MARK: - Init

    init(session: HouseholdSession, guests: GuestRepository) {
        self.session = session
        self.guests = guests
        self.clock = Int(Date().timeIntervalSince1970)
    }

    private func nextClock() -> SyncClock {
        clock = max(clock + 1, Int(Date().timeIntervalSince1970))
        return clock
    }

    // MARK: - Observe storeRevision

    /// Wire the revision observer via `ObservationReloader` (simmersmith-7mb) — re-registers
    /// before each reload so a bump during an in-flight reload is never missed.
    @ObservationIgnored
    private lazy var revisionReloader = ObservationReloader(
        track: { [weak self] in _ = self?.session.storeRevision },
        reload: { [weak self] in self?.reload() }
    )

    func startObserving() {
        revisionReloader.start()
    }

    // MARK: - Read (aggregate reassembly)

    /// Recompute `events` from the local store. Reassembles each `.event` record into a full
    /// `Event` aggregate (meals + ingredients + attendees-with-resolved-guest + grocery),
    /// indexing children once for the whole pass (avoid O(events × records) re-scans).
    func reload() {
        let store = session.store

        let mealRecords = store.records(ofType: HouseholdRecordType.eventMeal.recordTypeName)
        let ingredientRecords = store.records(ofType: HouseholdRecordType.eventMealIngredient.recordTypeName)
        let attendeeRecords = store.records(ofType: HouseholdRecordType.eventAttendee.recordTypeName)
        let groceryRecords = store.records(ofType: EventGroceryCodec.recordType)

        // Group meals by parent event ref.
        var mealsByEvent: [String: [CKRecord]] = [:]
        for rec in mealRecords {
            let eventID = refName(rec["event"])
            guard !eventID.isEmpty else { continue }
            mealsByEvent[eventID, default: []].append(rec)
        }

        // Group ingredients by parent eventMeal ref.
        var ingredientsByMeal: [String: [HouseholdRecordValue]] = [:]
        for rec in ingredientRecords {
            let mealID = refName(rec["eventMeal"])
            guard !mealID.isEmpty else { continue }
            ingredientsByMeal[mealID, default: []].append(
                HouseholdRecordCodec.decode(rec, as: .eventMealIngredient))
        }

        // Group attendees by parent event ref.
        var attendeesByEvent: [String: [CKRecord]] = [:]
        for rec in attendeeRecords {
            let eventID = refName(rec["event"])
            guard !eventID.isEmpty else { continue }
            attendeesByEvent[eventID, default: []].append(rec)
        }

        var result: [DomainEvent] = []
        for eventRecord in store.records(ofType: HouseholdRecordType.event.recordTypeName) {
            let eventID = eventRecord.recordID.recordName
            let eventValue = HouseholdRecordCodec.decode(eventRecord, as: .event)

            // Meals sorted by sortOrder then recordName for a stable menu order.
            let mealRecs = (mealsByEvent[eventID] ?? []).sorted { a, b in
                let sa = a["sortOrder"] as? Int ?? 0
                let sb = b["sortOrder"] as? Int ?? 0
                if sa != sb { return sa < sb }
                return a.recordID.recordName < b.recordID.recordName
            }
            let mealValues = mealRecs.map { HouseholdRecordCodec.decode($0, as: .eventMeal) }
            var ingByMealValue: [String: [HouseholdRecordValue]] = [:]
            for mealValue in mealValues {
                ingByMealValue[mealValue.recordName] = ingredientsByMeal[mealValue.recordName] ?? []
            }

            // Attendees (record values) for this event.
            let attendeeValues = (attendeesByEvent[eventID] ?? [])
                .map { HouseholdRecordCodec.decode($0, as: .eventAttendee) }

            // Base aggregate from the mapper (attendee guest = placeholder; grocery = []).
            let base = EventRecordMapper.event(
                from: eventValue,
                meals: mealValues,
                ingredientsByMeal: ingByMealValue,
                attendees: attendeeValues
            )

            // Resolve each attendee's live Guest from the store + inject this event's grocery.
            let resolved = injectResolved(
                into: base,
                attendees: attendeeValues,
                grocery: eventGroceryDicts(forEvent: eventID, groceryRecords: groceryRecords)
            )
            result.append(resolved)
        }

        // Newest first: dated events by date desc, then undated by updatedAt desc (dated before
        // undated — mirrors AppState.syncSummary ordering, inverted to newest-first here).
        result.sort { left, right in
            switch (left.eventDate, right.eventDate) {
            case let (l?, r?): return l > r
            case (nil, nil): return left.updatedAt > right.updatedAt
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }
        events = result
    }

    /// Look an event up by record name in the reassembled list.
    func event(forId eventID: String) -> DomainEvent? {
        events.first { $0.eventId == eventID }
    }

    // MARK: - Reassembly helpers

    /// Replace each attendee's placeholder `guest` with the live store Guest, and inject the
    /// event's grocery rows — both done via a JSON patch on the mapper's base aggregate (the
    /// mapper leaves the guest a placeholder and grocery empty by design).
    private func injectResolved(
        into base: DomainEvent,
        attendees: [HouseholdRecordValue],
        grocery: [[String: Any]]
    ) -> DomainEvent {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard var dict = (try? encoder.encode(base))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return base }

        // Resolve attendee guests.
        if var attendeeDicts = dict["attendees"] as? [[String: Any]] {
            for index in attendeeDicts.indices {
                guard let guestID = attendeeDicts[index]["guestId"] as? String,
                      let live = guests.guest(forId: guestID),
                      let liveData = try? encoder.encode(live),
                      let liveDict = try? JSONSerialization.jsonObject(with: liveData) as? [String: Any]
                else { continue }
                attendeeDicts[index]["guest"] = liveDict
            }
            dict["attendees"] = attendeeDicts
        }

        dict["groceryItems"] = grocery

        guard let patched = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap({ try? decoder.decode(DomainEvent.self, from: $0) })
        else { return base }
        return patched
    }

    /// Build the domain `EventGroceryItem` dicts for an event from its EventGroceryItem records.
    /// Rows are attributed to this event by the `<eventID>_eg_` record-name prefix minted at regen.
    private func eventGroceryDicts(forEvent eventID: String, groceryRecords: [CKRecord]) -> [[String: Any]] {
        let prefix = eventGroceryPrefix(eventID)
        return groceryRecords
            .filter { $0.recordID.recordName.hasPrefix(prefix) }
            .map { EventGroceryCodec.decode($0) }
            .map { domainEventGroceryDict(from: $0) }
    }

    /// Map a merge `EventGroceryItem` into the domain `EventGroceryItem`'s JSON shape. `eventQuantity`
    /// (this row's contribution) maps to the domain `totalQuantity`; `sourceMeals` (a JSON array
    /// string) is parsed back into `[String]`.
    private func domainEventGroceryDict(from item: GroceryMerge.EventGroceryItem) -> [String: Any] {
        var d: [String: Any] = [
            "groceryItemId": item.recordName,
            "ingredientName": item.ingredientName,
            "unit": item.unit,
            "quantityText": item.quantityText,
            "category": item.category,
            "sourceMeals": parseSourceMeals(item.sourceMeals),
            "notes": item.notes,
            "reviewFlag": item.reviewFlag,
        ]
        if let v = item.eventQuantity { d["totalQuantity"] = v }
        if let v = item.baseIngredientID { d["baseIngredientId"] = v }
        if let v = item.ingredientVariationID { d["ingredientVariationId"] = v }
        if let v = item.mergedIntoWeekID { d["mergedIntoWeekId"] = v }
        if let v = item.mergedIntoGroceryItemID { d["mergedIntoGroceryItemId"] = v }
        return d
    }

    /// Parse the generator's JSON-array source_meals string back into `[String]` (tolerant — falls
    /// back to a single-element list, or empty, if it isn't valid JSON).
    private func parseSourceMeals(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr
        }
        return raw.isEmpty ? [] : [raw]
    }

    // MARK: - Write: events

    /// Create a new event (+ its attendees). Returns the reloaded aggregate.
    @discardableResult
    func createEvent(
        name: String,
        eventDate: Date? = nil,
        occasion: String = "other",
        attendeeCount: Int = 0,
        notes: String = "",
        attendees: [(guestID: String, plusOnes: Int)] = [],
        knownGuestIDs: Set<String>? = nil
    ) throws -> DomainEvent? {
        let eventID = UUID().uuidString
        var scalars: [String: ScalarValue] = [
            "name": .string(name),
            "occasion": .string(occasion),
            "attendeeCount": .int(attendeeCount),
            "status": .string("planning"),
            "autoMergeGrocery": .bool(true),
            "createdAt": .date(Date()),
            "updatedAt": .date(Date()),
        ]
        if let eventDate { scalars["eventDate"] = .date(eventDate) }
        if !notes.isEmpty { scalars["notes"] = .string(notes) }
        try requireAcceptedSave(
            upsertRecord(HouseholdRecordValue(type: .event, recordName: eventID, scalars: scalars, refs: [:]))
        )
        try syncAttendees(eventID: eventID, attendees: attendees, knownGuestIDs: knownGuestIDs)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return event(forId: eventID)
    }

    /// Update an event's scalar fields + attendee set (det-keyed). Returns the reloaded aggregate.
    @discardableResult
    func updateEvent(
        eventID: String,
        name: String,
        eventDate: Date?,
        occasion: String,
        attendeeCount: Int,
        notes: String,
        status: String,
        attendees: [(guestID: String, plusOnes: Int)],
        knownGuestIDs: Set<String>? = nil
    ) throws -> DomainEvent? {
        guard let existing = session.store.record(
            for: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)) else { return nil }
        try authorizeAttendeeDeletions(
            eventID: eventID,
            attendees: attendees,
            knownGuestIDs: knownGuestIDs
        )
        existing["name"] = name as CKRecordValue
        existing["eventDate"] = eventDate as CKRecordValue?
        existing["occasion"] = occasion as CKRecordValue
        existing["attendeeCount"] = attendeeCount as CKRecordValue
        existing["notes"] = notes as CKRecordValue
        existing["status"] = status as CKRecordValue
        existing["updatedAt"] = Date() as CKRecordValue
        try requireAcceptedSave(session.engine.save(existing))
        try syncAttendees(eventID: eventID, attendees: attendees, knownGuestIDs: knownGuestIDs)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return event(forId: eventID)
    }

    /// Delete an event whole. UNMERGE from any linked week FIRST (server authority:
    /// events.py delete_event unmerges before `session.delete(event)`) — otherwise the cascade
    /// drops the event's own rows but leaves the week's GroceryItems with stale eventQuantity +
    /// dangling mergedIntoGroceryItemID, and orphaned event-only rows. The engine's unmerge
    /// preserves week rows carrying user investment. Then cascade-delete the `.event` root so its
    /// `.eventMeal` (+ ingredient) and `.eventAttendee` children fall with it. The event's own
    /// EventGroceryItem rows are NOT cascade children (no CK parent ref) — clear them explicitly.
    @discardableResult
    func deleteEvent(eventID: String) throws -> HouseholdDataPlaneResult {
        let authorization = session.engine.dataPlaneResult(for: .deleteCascading)
        guard authorization == .allowed else { return authorization }
        if let linkedWeekID = mergeEvent(forId: eventID)?.linkedWeekID, !linkedWeekID.isEmpty {
            try unmergeViaAdapter(eventID: eventID, weekID: linkedWeekID, keepLink: false)
        }
        let groceryResult = deleteEventGroceryRows(forEvent: eventID)
        guard groceryResult == .allowed else { return groceryResult }
        let cascadeResult = session.engine.deleteCascading(
            CKRecord.ID(recordName: eventID, zoneID: session.zoneID))
        guard cascadeResult == .allowed else { return cascadeResult }
        reload()
        Task { [weak self] in await self?.drainSync() }
        return .allowed
    }

    // MARK: - Write: meals

    /// One inline ingredient line for an event meal (the analog of the server's
    /// EventMealIngredient payload in `replace_event_meals`). Written as a
    /// `.eventMealIngredient` cascade-child of the meal so the event-grocery generator can
    /// aggregate it — without these, an AI-generated (recipe-less) dish contributes ZERO
    /// grocery lines and the event grocery comes out empty.
    struct EventMealIngredientInput {
        var ingredientName: String
        var quantity: Double?
        var unit: String
        var prep: String
        var category: String
        var notes: String
        var baseIngredientID: String?
        var ingredientVariationID: String?

        init(
            ingredientName: String,
            quantity: Double? = nil,
            unit: String = "",
            prep: String = "",
            category: String = "",
            notes: String = "",
            baseIngredientID: String? = nil,
            ingredientVariationID: String? = nil
        ) {
            self.ingredientName = ingredientName
            self.quantity = quantity
            self.unit = unit
            self.prep = prep
            self.category = category
            self.notes = notes
            self.baseIngredientID = baseIngredientID
            self.ingredientVariationID = ingredientVariationID
        }
    }

    /// Add a meal to an event. `sortOrder` = max existing + 1. Optionally writes the dish's
    /// inline `.eventMealIngredient` grandchildren (so a recipe-less dish still feeds the
    /// event grocery), and stamps `aiGenerated` + `constraintCoverage` (server authority:
    /// `events.py replace_event_meals` writes both per dish). Returns the reloaded aggregate.
    @discardableResult
    func addEventMeal(
        eventID: String,
        role: String,
        recipeName: String,
        recipeID: String? = nil,
        servings: Double? = nil,
        notes: String = "",
        assignedGuestID: String? = nil,
        aiGenerated: Bool = false,
        constraintCoverage: [String] = [],
        ingredients: [EventMealIngredientInput] = []
    ) throws -> DomainEvent? {
        let existing = session.store.records(ofType: HouseholdRecordType.eventMeal.recordTypeName)
            .filter { refName($0["event"]) == eventID }
        let nextSort = (existing.compactMap { $0["sortOrder"] as? Int }.max() ?? -1) + 1

        let mealID = UUID().uuidString
        var scalars: [String: ScalarValue] = [
            "role": .string(role),
            "recipeName": .string(recipeName),
            "scaleMultiplier": .double(1.0),
            "sortOrder": .int(nextSort),
            "aiGenerated": .bool(aiGenerated),
            "approved": .bool(false),
            // constraintCoverage: the resolved guest-coverage (guest ids) → JSON-array string.
            // Mirrors EventRecordMapper.encodeStringArray; "[]" for an empty list, which the
            // reverse map decodes back to an empty [String].
            "constraintCoverage": .string(encodeStringArray(constraintCoverage)),
            "createdAt": .date(Date()),
            "updatedAt": .date(Date()),
        ]
        if let servings { scalars["servings"] = .double(servings) }
        if !notes.isEmpty { scalars["notes"] = .string(notes) }

        var refs: [String: String] = ["event": eventID]
        if let recipeID { refs["recipe"] = recipeID }
        if let assignedGuestID { refs["assignedGuest"] = assignedGuestID }

        try requireAcceptedSave(
            upsertRecord(HouseholdRecordValue(type: .eventMeal, recordName: mealID, scalars: scalars, refs: refs))
        )
        try writeEventMealIngredients(mealID: mealID, ingredients: ingredients)
        try afterMealMutation(eventID: eventID)
        return event(forId: eventID)
    }

    /// Write a meal's inline ingredient lines as `.eventMealIngredient` cascade-children
    /// (det record names `<mealID>_ing_<n>`, mirroring EventRecordMapper.buildIngredientRecord
    /// + the server's per-meal-ingredient id `{meal.id}:{index}`). normalizedName is computed
    /// from the display name (the server lowercases `normalized_name or ingredient_name`).
    private func writeEventMealIngredients(
        mealID: String,
        ingredients: [EventMealIngredientInput]
    ) throws {
        for (index, ing) in ingredients.enumerated() {
            let recordName = "\(mealID)_ing_\(index)"
            var scalars: [String: ScalarValue] = [
                "ingredientName": .string(ing.ingredientName),
                "normalizedName": .string(ing.ingredientName.lowercased()),
                "resolutionStatus": .string("unresolved"),
                "createdAt": .date(Date()),
                "updatedAt": .date(Date()),
            ]
            if let q = ing.quantity { scalars["quantity"] = .double(q) }
            if !ing.unit.isEmpty { scalars["unit"] = .string(ing.unit) }
            if !ing.prep.isEmpty { scalars["prep"] = .string(ing.prep) }
            if !ing.category.isEmpty { scalars["category"] = .string(ing.category) }
            if !ing.notes.isEmpty { scalars["notes"] = .string(ing.notes) }

            var refs: [String: String] = ["eventMeal": mealID]
            if let v = ing.baseIngredientID, !v.isEmpty { refs["baseIngredientID"] = v }
            if let v = ing.ingredientVariationID, !v.isEmpty { refs["ingredientVariationID"] = v }

            try requireAcceptedSave(upsertRecord(HouseholdRecordValue(
                type: .eventMealIngredient, recordName: recordName, scalars: scalars, refs: refs)))
        }
    }

    /// Delete the event's AI-generated meals, preserving manual ones. Mirrors the
    /// `preserve_manual=True` path of the server's `replace_event_meals`: regen must REPLACE
    /// (not accrete) prior AI dishes while keeping user/guest-assigned (manual) dishes. Each
    /// meal cascade-deletes its `.eventMealIngredient` grandchildren. Does NOT refresh grocery
    /// — the caller adds the fresh AI dishes and triggers a single regen afterward.
    func deleteAIGeneratedEventMeals(eventID: String) throws {
        let aiMealIDs = session.store.records(ofType: HouseholdRecordType.eventMeal.recordTypeName)
            .filter { refName($0["event"]) == eventID }
            .filter { ($0["aiGenerated"] as? Int ?? 0) != 0 }
            .map { $0.recordID.recordName }
        for mealID in aiMealIDs {
            let result = session.engine.deleteCascading(
                CKRecord.ID(recordName: mealID, zoneID: session.zoneID))
            guard result == .allowed else { throw result }
        }
    }

    /// Patch an existing meal. `clearAssignee` nulls the assignedGuest ref (a guest no longer
    /// bringing the dish → it re-enters grocery aggregation). Returns the reloaded aggregate.
    @discardableResult
    func updateEventMeal(
        eventID: String,
        mealID: String,
        role: String? = nil,
        recipeID: String? = nil,
        recipeName: String? = nil,
        servings: Double? = nil,
        notes: String? = nil,
        assignedGuestID: String? = nil,
        clearAssignee: Bool = false
    ) throws -> DomainEvent? {
        guard let existing = session.store.record(
            for: CKRecord.ID(recordName: mealID, zoneID: session.zoneID)) else { return nil }
        if let role { existing["role"] = role as CKRecordValue }
        if let recipeName { existing["recipeName"] = recipeName as CKRecordValue }
        if let servings { existing["servings"] = servings as CKRecordValue }
        if let notes { existing["notes"] = notes as CKRecordValue }
        if let recipeID {
            existing["recipe"] = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: recipeID, zoneID: session.zoneID), action: .none)
        }
        if clearAssignee {
            existing["assignedGuest"] = nil
        } else if let assignedGuestID {
            existing["assignedGuest"] = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: assignedGuestID, zoneID: session.zoneID), action: .none)
        }
        existing["updatedAt"] = Date() as CKRecordValue
        try requireAcceptedSave(session.engine.save(existing))
        try afterMealMutation(eventID: eventID)
        return event(forId: eventID)
    }

    /// Delete a meal (cascade-deletes its `.eventMealIngredient` grandchildren). Returns the
    /// reloaded aggregate.
    @discardableResult
    func deleteEventMeal(eventID: String, mealID: String) throws -> DomainEvent? {
        let id = CKRecord.ID(recordName: mealID, zoneID: session.zoneID)
        guard session.store.record(for: id) != nil else { return event(forId: eventID) }
        let result = session.engine.deleteCascading(id)
        guard result == .allowed else { throw result }
        try afterMealMutation(eventID: eventID)
        return event(forId: eventID)
    }

    /// Shared tail of every meal mutation: regen the event grocery — `refreshEventGrocery` already
    /// re-applies the auto-merge policy + reloads + drains as its final steps, so this tail must NOT
    /// re-run `applyAutoMergePolicy` on the stale pre-drain state (it would double-apply).
    private func afterMealMutation(eventID: String) throws {
        try refreshEventGrocery(eventID: eventID)
    }

    // MARK: - Attendees (det-keyed <eventID>_<guestID>)

    /// Reconcile the event's `.eventAttendee` children against the desired set. Det-keyed by
    /// `<eventID>_<guestID>`; upsert the desired, explicitly delete the removed (NOT cascade — an
    /// attendee is not a cascade parent).
    ///
    /// `knownGuestIDs` is the BASELINE-AWARE DELETE guard (simmersmith-f0s — mirrors
    /// WeekRepository.saveWeekMeals/WeekMealDeletePolicy, simmersmith-eky): the guest ids present
    /// in the caller's SOURCE snapshot. A store attendee is only ever a deletion candidate if the
    /// caller both knew about it (in `knownGuestIDs`) and dropped it (not in `attendees`) — a
    /// partner's concurrently-synced attendee add the caller's snapshot never saw is always kept.
    /// `nil` preserves the pre-fix behavior (assume the caller knows about every attendee
    /// currently in the store) for callers not yet threading a baseline through
    /// createEvent/updateEvent.
    private func syncAttendees(
        eventID: String,
        attendees: [(guestID: String, plusOnes: Int)],
        knownGuestIDs: Set<String>? = nil
    ) throws {
        let existingRecords = Dictionary(
            uniqueKeysWithValues: session.store.records(ofType: HouseholdRecordType.eventAttendee.recordTypeName)
                .filter { refName($0["event"]) == eventID }
                .map { ($0.recordID.recordName, $0) }
        )
        let existingNames = Set(existingRecords.keys)
        var desiredNames = Set<String>()
        for attendee in attendees {
            desiredNames.insert("\(eventID)_\(attendee.guestID)")
        }
        let deletionNames = attendeeDeletionNames(
            eventID: eventID,
            existingNames: existingNames,
            desiredNames: desiredNames,
            knownGuestIDs: knownGuestIDs
        )
        try authorizeAttendeeDeletions(deletionNames)
        for attendee in attendees {
            let recordName = "\(eventID)_\(attendee.guestID)"
            var scalars: [String: ScalarValue] = [
                "plusOnes": .int(attendee.plusOnes),
                "updatedAt": .date(Date()),
            ]
            // Stamp createdAt only when minting a brand-new attendee row — an existing row's
            // createdAt must survive every re-sync (this upsert used to rewrite it to Date() on
            // every save, regardless of whether the attendee already existed).
            if existingRecords[recordName] == nil {
                scalars["createdAt"] = .date(Date())
            }
            let value = HouseholdRecordValue(
                type: .eventAttendee,
                recordName: recordName,
                scalars: scalars,
                refs: ["event": eventID, "guest": attendee.guestID]
            )
            try requireAcceptedSave(upsertRecord(value))
        }
        // Baseline-aware delete: reuses WeekMealDeletePolicy.toDelete (simmersmith-eky) — the
        // formula (existing − desired) ∩ known is domain-agnostic Set algebra, not meal-specific.
        for name in deletionNames {
            let result = session.engine.delete(CKRecord.ID(recordName: name, zoneID: session.zoneID))
            guard result == .allowed else { throw result }
        }
    }

    private func authorizeAttendeeDeletions(
        eventID: String,
        attendees: [(guestID: String, plusOnes: Int)],
        knownGuestIDs: Set<String>?
    ) throws {
        let existingNames = Set(
            session.store.records(ofType: HouseholdRecordType.eventAttendee.recordTypeName)
                .filter { refName($0["event"]) == eventID }
                .map { $0.recordID.recordName }
        )
        let desiredNames = Set(attendees.map { "\(eventID)_\($0.guestID)" })
        try authorizeAttendeeDeletions(
            attendeeDeletionNames(
                eventID: eventID,
                existingNames: existingNames,
                desiredNames: desiredNames,
                knownGuestIDs: knownGuestIDs
            )
        )
    }

    private func attendeeDeletionNames(
        eventID: String,
        existingNames: Set<String>,
        desiredNames: Set<String>,
        knownGuestIDs: Set<String>?
    ) -> Set<String> {
        let known = knownGuestIDs.map { ids in Set(ids.map { "\(eventID)_\($0)" }) } ?? existingNames
        return WeekMealDeletePolicy.toDelete(existing: existingNames, desired: desiredNames, known: known)
    }

    private func authorizeAttendeeDeletions(_ deletionNames: Set<String>) throws {
        guard !deletionNames.isEmpty else { return }
        let authorization = session.engine.dataPlaneResult(for: .delete)
        guard authorization == .allowed else { throw authorization }
    }

    // MARK: - Event-grocery regen (T2 generator port wiring)

    /// Regenerate the event's grocery rows from its current meals. Wipe-and-rebuild (event regen
    /// carries no sticky state — EventGroceryGenerator). Wiring order mirrors the server's
    /// regenerate_event_grocery: (1) unmerge from any linked week first so stale week
    /// contributions are removed; (2) hard-delete the event's prior rows; (3) generate the fresh
    /// set with `<eventID>_eg_` record names + write them; (4) re-apply the auto-merge policy so
    /// the fresh rows flow back into the target week. Callers that drive a fuller mutation
    /// (meal add/delete) wrap this via `afterMealMutation`; this method also stands alone.
    func refreshEventGrocery(eventID: String) throws {
        // (1) Drop any stale merge into the linked week before rebuilding.
        if let linkedWeekID = mergeEvent(forId: eventID)?.linkedWeekID, !linkedWeekID.isEmpty {
            try unmergeViaAdapter(eventID: eventID, weekID: linkedWeekID, keepLink: true)
        }

        // (2) Hard-delete the event's prior EventGroceryItem rows.
        let deleteResult = deleteEventGroceryRows(forEvent: eventID)
        guard deleteResult == .allowed else { throw deleteResult }

        // (3) Generate fresh rows from the event's meals + write them. Record names carry the
        //     `<eventID>_eg_<n>` prefix so this event's rows are a cheap, deterministic scan.
        let meals = eventGroceryMeals(eventID: eventID)
        let prefix = eventGroceryPrefix(eventID)
        var counter = 0
        let fresh = GroceryMerge.EventGroceryGenerator.regenerate(
            eventID: eventID,
            meals: meals,
            clock: nextClock(),
            newRecordName: { _ in
                defer { counter += 1 }
                return "\(prefix)\(counter)"
            }
        )
        for row in fresh {
            try requireAcceptedSave(saveEventRow(row))
        }

        // (4) Re-flow into the target week per policy (no-op when autoMerge off / no target).
        try applyAutoMergePolicy(eventID: eventID)

        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    /// Build the EventGroceryGenerator input from the event's `.eventMeal` records. Recipe-backed
    /// meals resolve ingredients from the recipe's `.recipeIngredient` records (scaled by the
    /// recipe's servings); inline meals (no recipe) use their own `.eventMealIngredient` lines.
    /// Guest-assigned meals carry their `assignedGuestID` so the generator skips them (the guest
    /// is bringing the dish).
    private func eventGroceryMeals(eventID: String) -> [GroceryMerge.EventGroceryMeal] {
        let store = session.store

        // Recipe ingredient lines + servings, indexed by recipe.
        var ingredientsByRecipe: [String: [GroceryMerge.GroceryIngredientLine]] = [:]
        for rec in store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName) {
            let value = HouseholdRecordCodec.decode(rec, as: .recipeIngredient)
            guard let recipeID = value.refs["recipe"] else { continue }
            ingredientsByRecipe[recipeID, default: []].append(line(fromRecipeIngredient: value))
        }
        var servingsByRecipe: [String: Double] = [:]
        for rec in store.records(ofType: HouseholdRecordType.recipe.recordTypeName) {
            if let s = rec["servings"] as? Double { servingsByRecipe[rec.recordID.recordName] = s }
        }

        // Inline event-meal ingredients, indexed by parent eventMeal ref.
        var inlineByMeal: [String: [GroceryMerge.GroceryIngredientLine]] = [:]
        for rec in store.records(ofType: HouseholdRecordType.eventMealIngredient.recordTypeName) {
            let mealID = refName(rec["eventMeal"])
            guard !mealID.isEmpty else { continue }
            let value = HouseholdRecordCodec.decode(rec, as: .eventMealIngredient)
            inlineByMeal[mealID, default: []].append(line(fromEventIngredient: value))
        }

        let mealRecs = store.records(ofType: HouseholdRecordType.eventMeal.recordTypeName)
            .filter { refName($0["event"]) == eventID }

        return mealRecs.map { mealRec in
            let mealID = mealRec.recordID.recordName
            let recipeID = refName(mealRec["recipe"])
            let assignedGuestID = refName(mealRec["assignedGuest"])
            let baseServings = recipeID.isEmpty ? nil : servingsByRecipe[recipeID]
            // Recipe-backed → recipe lines; inline → the meal's own ingredient records.
            let ingredients = recipeID.isEmpty
                ? (inlineByMeal[mealID] ?? [])
                : (ingredientsByRecipe[recipeID] ?? [])

            return GroceryMerge.EventGroceryMeal(
                mealID: mealID,
                assignedGuestID: assignedGuestID.isEmpty ? nil : assignedGuestID,
                scaleMultiplier: mealRec["scaleMultiplier"] as? Double,
                servings: mealRec["servings"] as? Double,
                baseServings: baseServings,
                ingredients: ingredients
            )
        }
    }

    private func line(fromRecipeIngredient value: HouseholdRecordValue) -> GroceryMerge.GroceryIngredientLine {
        GroceryMerge.GroceryIngredientLine(
            ingredientName: scalarString(value, "ingredientName") ?? "",
            normalizedName: scalarString(value, "normalizedName") ?? "",
            unit: scalarString(value, "unit") ?? "",
            quantity: scalarDouble(value, "quantity"),
            quantityText: "",
            category: scalarString(value, "category") ?? "",
            notes: scalarString(value, "notes") ?? "",
            prep: scalarString(value, "prep") ?? "",
            baseIngredientID: value.refs["baseIngredientID"],
            ingredientVariationID: value.refs["ingredientVariationID"],
            resolutionStatus: scalarString(value, "resolutionStatus") ?? "unresolved"
        )
    }

    private func line(fromEventIngredient value: HouseholdRecordValue) -> GroceryMerge.GroceryIngredientLine {
        GroceryMerge.GroceryIngredientLine(
            ingredientName: scalarString(value, "ingredientName") ?? "",
            normalizedName: "",
            unit: scalarString(value, "unit") ?? "",
            quantity: scalarDouble(value, "quantity"),
            quantityText: "",
            category: scalarString(value, "category") ?? "",
            notes: scalarString(value, "notes") ?? "",
            prep: scalarString(value, "prep") ?? "",
            baseIngredientID: value.refs["baseIngredientID"],
            ingredientVariationID: value.refs["ingredientVariationID"],
            resolutionStatus: "unresolved"
        )
    }

    // MARK: - Merge / unmerge (wire the built EventMergeAdapter — do NOT reimplement)

    /// Merge the event's grocery into a specific week via the adapter (sets linkedWeekID, marks
    /// event rows merged, bumps matched week rows' eventQuantity). Returns the reloaded aggregate.
    @discardableResult
    func mergeEventGroceryIntoWeek(eventID: String, weekID: String) throws -> DomainEvent? {
        guard let mergeEv = mergeEvent(forId: eventID) else { return nil }
        let adapter = EventMergeAdapter(engine: session.engine, zoneID: session.zoneID)
        _ = try adapter.merge(event: mergeEv, eventRows: eventRows(forEvent: eventID), intoWeek: weekID)
        // PIN the manual merge (server authority: events.py merge route sets manually_merged=True).
        // A later meal edit's applyAutoMergePolicy keeps a pinned merge in place instead of
        // silently relocating it (the engine's manuallyMerged-pin path depends on this flag).
        try requireAcceptedSave(setManuallyMerged(eventID: eventID, true))
        reload()
        Task { [weak self] in await self?.drainSync() }
        return event(forId: eventID)
    }

    /// Unmerge the event's grocery from a week via the adapter. The adapter's engine HARD-deletes
    /// event-only week rows but PRESERVES week rows with user investment (override/check/user-added)
    /// — this wiring must not bypass that, so it never deletes week rows itself. Returns the reloaded
    /// aggregate.
    @discardableResult
    func unmergeEventGroceryFromWeek(eventID: String, weekID: String) throws -> DomainEvent? {
        try unmergeViaAdapter(eventID: eventID, weekID: weekID, keepLink: false)
        // Clear the manual pin (server authority: events.py unmerge route sets manually_merged=False)
        // so the auto-merge policy resumes for this event.
        try requireAcceptedSave(setManuallyMerged(eventID: eventID, false))
        reload()
        Task { [weak self] in await self?.drainSync() }
        return event(forId: eventID)
    }

    private func unmergeViaAdapter(eventID: String, weekID: String, keepLink: Bool) throws {
        guard let mergeEv = mergeEvent(forId: eventID) else { return }
        let adapter = EventMergeAdapter(engine: session.engine, zoneID: session.zoneID)
        _ = try adapter.unmerge(event: mergeEv, eventRows: eventRows(forEvent: eventID),
                                fromWeek: weekID, keepLink: keepLink)
    }

    // MARK: - Auto-merge policy

    /// Toggle the event's autoMergeGrocery flag, then re-apply the policy (which merges into /
    /// unmerges from the resolved target week accordingly). Returns the reloaded aggregate.
    @discardableResult
    func toggleEventAutoMerge(eventID: String, enabled: Bool) throws -> DomainEvent? {
        guard let existing = session.store.record(
            for: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)) else { return nil }
        existing["autoMergeGrocery"] = (enabled ? 1 : 0) as CKRecordValue
        existing["updatedAt"] = Date() as CKRecordValue
        try requireAcceptedSave(session.engine.save(existing))
        try applyAutoMergePolicy(eventID: eventID)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return event(forId: eventID)
    }

    /// Re-resolve the event's target week and merge/unmerge to match its policy, via the pure
    /// `GroceryMerge.EventMergeEngine.applyAutoMergePolicy`. Applies the resulting mutations through the engine:
    /// week grocery upserts, event-row pointer updates, hard-deletes, and the event's linkedWeekID.
    /// No-op when the event isn't locally present.
    func applyAutoMergePolicy(eventID: String) throws {
        guard let mergeEv = mergeEvent(forId: eventID) else { return }

        // Build the household's weeks (merge value type) + each week's current grocery rows.
        let weekRecords = session.store.records(ofType: HouseholdRecordType.week.recordTypeName)
        var weeksByID: [String: GroceryMerge.Week] = [:]
        var weekRowsByID: [String: [GroceryMerge.GroceryItem]] = [:]
        for rec in weekRecords {
            let weekID = rec.recordID.recordName
            weeksByID[weekID] = GroceryMerge.Week(
                recordName: weekID,
                weekStart: isoDayString(rec["weekStart"] as? Date),
                weekEnd: isoDayString(rec["weekEnd"] as? Date)
            )
        }
        for rec in session.store.records(ofType: GroceryCodec.recordType) {
            guard let weekID = rec["weekID"] as? String else { continue }
            weekRowsByID[weekID, default: []].append(GroceryCodec.decode(rec))
        }

        let outcome = GroceryMerge.EventMergeEngine.applyAutoMergePolicy(
            event: mergeEv,
            eventRows: eventRows(forEvent: eventID),
            weeksByID: weeksByID,
            weekRowsByID: weekRowsByID,
            makeID: { UUID().uuidString }
        )

        if !outcome.hardDeletedRecordNames.isEmpty {
            let authorization = session.engine.dataPlaneResult(for: .delete)
            guard authorization == .allowed else { throw authorization }
        }

        // Apply: week grocery upserts (change-tag-preserving), hard-deletes, event-row pointers,
        // and the event link.
        for (_, rows) in outcome.weekRowsByID {
            for row in rows {
                try requireAcceptedSave(saveGrocery(row))
            }
        }
        for name in outcome.hardDeletedRecordNames {
            let deletion = session.engine.delete(CKRecord.ID(recordName: name, zoneID: session.zoneID))
            guard deletion == .allowed else { throw deletion }
        }
        for row in outcome.eventRows {
            try requireAcceptedSave(saveEventRow(row))
        }
        try requireAcceptedSave(updateEventLink(
            eventID: eventID,
            linkedWeekID: outcome.event.linkedWeekID
        ))
    }

    // MARK: - Merge value-type bridge

    /// Build the thin `GroceryMerge.Event` the merge engine/adapter consume, from the `.event`
    /// record's authoritative fields (manuallyMerged is record-only — not on the domain Event).
    private func mergeEvent(forId eventID: String) -> GroceryMerge.Event? {
        guard let rec = session.store.record(
            for: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)) else { return nil }
        return GroceryMerge.Event(
            recordName: eventID,
            name: rec["name"] as? String ?? "",
            eventDate: isoDayString(rec["eventDate"] as? Date),
            linkedWeekID: refName(rec["linkedWeekID"]).isEmpty
                ? (rec["linkedWeekID"] as? String) : refName(rec["linkedWeekID"]),
            manuallyMerged: (rec["manuallyMerged"] as? Int ?? 0) != 0,
            autoMergeGrocery: (rec["autoMergeGrocery"] as? Int ?? 1) != 0
        )
    }

    /// This event's EventGroceryItem rows (merge type), keyed by the `<eventID>_eg_` prefix.
    private func eventRows(forEvent eventID: String) -> [GroceryMerge.EventGroceryItem] {
        let prefix = eventGroceryPrefix(eventID)
        return session.store.records(ofType: EventGroceryCodec.recordType)
            .filter { $0.recordID.recordName.hasPrefix(prefix) }
            .map(EventGroceryCodec.decode)
    }

    private func deleteEventGroceryRows(forEvent eventID: String) -> HouseholdDataPlaneResult {
        let prefix = eventGroceryPrefix(eventID)
        for rec in session.store.records(ofType: EventGroceryCodec.recordType)
            where rec.recordID.recordName.hasPrefix(prefix) {
            let result = session.engine.delete(rec.recordID)
            guard result == .allowed else { return result }
        }
        return .allowed
    }

    private func eventGroceryPrefix(_ eventID: String) -> String { "\(eventID)_eg_" }

    private func updateEventLink(eventID: String, linkedWeekID: String?) -> Bool {
        guard let rec = session.store.record(
            for: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)) else { return false }
        rec["linkedWeekID"] = linkedWeekID as CKRecordValue?
        rec["updatedAt"] = Date() as CKRecordValue
        return session.engine.save(rec)
    }

    /// Write the event's `manuallyMerged` flag (stored as Int, like autoMergeGrocery) + bump
    /// updatedAt. The merge codec stores it + the `mergeEvent(forId:)` bridge reads it; only the
    /// manual merge/unmerge entry points write it (server authority: events.py:641 / :674).
    private func setManuallyMerged(eventID: String, _ value: Bool) -> Bool {
        guard let rec = session.store.record(
            for: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)) else { return false }
        rec["manuallyMerged"] = (value ? 1 : 0) as CKRecordValue
        rec["updatedAt"] = Date() as CKRecordValue
        return session.engine.save(rec)
    }

    // MARK: - Save helpers (change-tag-preserving upserts; mirror EventMergeAdapter)

    private func requireAcceptedSave(_ accepted: Bool) throws {
        guard accepted else {
            throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
        }
    }

    private func saveGrocery(_ item: GroceryMerge.GroceryItem) -> Bool {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            GroceryCodec.encode(item, into: existing)
            return session.engine.save(existing)
        } else {
            return session.engine.save(GroceryCodec.makeRecord(item, zoneID: session.zoneID))
        }
    }

    private func saveEventRow(_ item: GroceryMerge.EventGroceryItem) -> Bool {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            EventGroceryCodec.encode(item, into: existing)
            return session.engine.save(existing)
        } else {
            return session.engine.save(EventGroceryCodec.makeRecord(item, zoneID: session.zoneID))
        }
    }

    // MARK: - Manifest upsert (mirror WeekRepository.upsertRecord)

    private func upsertRecord(_ value: HouseholdRecordValue) -> Bool {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            let refKinds = Dictionary(uniqueKeysWithValues: value.type.refs.map { ($0.name, $0.kind) })
            let fieldTypes = Dictionary(uniqueKeysWithValues: value.type.fields.map { ($0.name, $0.type) })

            for (name, scalar) in value.scalars {
                guard fieldTypes[name] != nil else { continue }
                existing[name] = ckValue(for: scalar)
            }
            for (name, target) in value.refs {
                guard let kind = refKinds[name] else { continue }
                switch kind {
                case .crossDBString:
                    existing[name] = target as CKRecordValue
                case .setNullInZone:
                    existing[name] = CKRecord.Reference(
                        recordID: CKRecord.ID(recordName: target, zoneID: session.zoneID), action: .none)
                case .cascadeParent:
                    existing[name] = CKRecord.Reference(
                        recordID: CKRecord.ID(recordName: target, zoneID: session.zoneID), action: .deleteSelf)
                }
            }
            return session.engine.save(existing)
        } else {
            return session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
    }

    /// JSON-encode a `[String]` to the same wire shape `EventRecordMapper.encodeStringArray`
    /// produces for `constraintCoverage` (that helper is internal to SimmerSmithKit). "[]" for
    /// an empty list — what the reverse map decodes back to an empty `[String]`.
    private func encodeStringArray(_ arr: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v):    return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v):   return v as CKRecordValue
        case .bool(let v):   return (v ? 1 : 0) as CKRecordValue
        }
    }

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[EventRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }

    // MARK: - Scalar accessors

    private func refName(_ value: Any?) -> String {
        (value as? CKRecord.Reference)?.recordID.recordName ?? ""
    }

    private func scalarString(_ value: HouseholdRecordValue, _ key: String) -> String? {
        if case let .string(v) = value.scalars[key] { return v }
        return nil
    }

    private func scalarDouble(_ value: HouseholdRecordValue, _ key: String) -> Double? {
        if case let .double(v) = value.scalars[key] { return v }
        return nil
    }

    /// ISO-8601 day string (UTC) for the merge engine's lexical date comparison; "" when no date.
    private func isoDayString(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
#endif
