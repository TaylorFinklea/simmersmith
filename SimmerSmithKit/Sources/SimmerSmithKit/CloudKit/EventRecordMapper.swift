import Foundation
import HouseholdRecords

// SP-C Task 4 — Event/Guest ⇄ CloudKit records mapper (both directions).
//
// Mirrors WeekRecordMapper in structure and conventions. Maps an Event aggregate
// to its primary .event record plus .eventMeal children, their .eventMealIngredient
// grandchildren, and .eventAttendee children. Maps Guest to/from its .guest record.
//
// Field classification:
//   A. Direct scalar ↔ record scalar field (1:1)
//   B. Serialised scalar — constraintCoverage: [String] ↔ .string (JSON array, like recipe tags)
//   C. References — .event: linkedWeekID (.crossDBString)
//                   .eventAttendee: event (.cascadeParent), guest (.setNullInZone)
//                   .eventMeal: event (.cascadeParent), recipe (.setNullInZone),
//                               assignedGuest (.setNullInZone)
//                   .eventMealIngredient: eventMeal (.cascadeParent),
//                                        baseIngredientID (.crossDBString),
//                                        ingredientVariationID (.crossDBString)
//   D. Derived / NOT stored — nil/recompute on reverse map:
//      Event: mealCount (derived count), attendees[].guest (nested Guest resolved by
//             GuestRepository), groceryItems (EventGroceryCodec), pantrySupplements (DEFERRED)
//      EventMealIngredient: normalizedName (not on domain struct; skipped on forward map)
//      manuallyMerged — merge-engine-owned CloudKit field; not on domain Event struct;
//                       stored on the record but not surfaced in the reverse Event
//
// EventGroceryItem is NOT mapped here — it is owned by EventGroceryCodec.
// pantrySupplements are DEFERRED (M28, Pantry plane slice 5) — omitted.
// Attendees use det-key <eventID>_<guestID> per manifest namePolicy.

public enum EventRecordMapper {

    // MARK: - Shared formatters

    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Event aggregate → Records

    /// Map an `Event` to its primary record plus meal, ingredient, and attendee child records.
    /// EventGroceryItems are excluded — they are owned by EventGroceryCodec.
    public static func records(from event: Event) -> (
        event: HouseholdRecordValue,
        meals: [HouseholdRecordValue],
        ingredients: [HouseholdRecordValue],
        attendees: [HouseholdRecordValue]
    ) {
        let eventRecord = buildEventRecord(event)
        var mealRecords: [HouseholdRecordValue] = []
        var ingredientRecords: [HouseholdRecordValue] = []
        var attendeeRecords: [HouseholdRecordValue] = []

        for meal in event.meals {
            mealRecords.append(buildMealRecord(meal, eventId: event.eventId))
            for (idx, ing) in meal.ingredients.enumerated() {
                ingredientRecords.append(buildIngredientRecord(ing, eventMealId: meal.mealId, fallbackIndex: idx))
            }
        }

        for attendee in event.attendees {
            attendeeRecords.append(buildAttendeeRecord(attendee, eventId: event.eventId))
        }

        return (eventRecord, mealRecords, ingredientRecords, attendeeRecords)
    }

    // MARK: - Records → Event aggregate

    /// Reconstruct an `Event` from its CloudKit record set.
    /// Category-D (derived) fields are returned as nil/0/[].
    /// Caller supplies pre-grouped meals→ingredients and attendees.
    /// groceryItems must be assembled separately via EventGroceryCodec.
    public static func event(
        from rec: HouseholdRecordValue,
        meals: [HouseholdRecordValue],
        ingredientsByMeal: [String: [HouseholdRecordValue]],
        attendees: [HouseholdRecordValue]
    ) -> Event {
        let s = rec.scalars

        var dict: [String: Any] = [
            "eventId": rec.recordName,
            "name": string(s, "name") ?? "",
            "occasion": string(s, "occasion") ?? "other",
            "attendeeCount": int(s, "attendeeCount") ?? 0,
            "notes": string(s, "notes") ?? "",
            "status": string(s, "status") ?? "planning",
            "autoMergeGrocery": bool(s, "autoMergeGrocery") ?? true,
            // Derived (§D) — NOT echoed; recompute from child records or EventGroceryCodec.
            "mealCount": meals.count,
            "meals": [],
            "attendees": [],
            "groceryItems": [],
            "pantrySupplements": [],
        ]

        dict["createdAt"] = iso8601(date(s, "createdAt") ?? Date(timeIntervalSince1970: 0))
        dict["updatedAt"] = iso8601(date(s, "updatedAt") ?? Date())

        // Optional event date.
        if let v = date(s, "eventDate") { dict["eventDate"] = iso8601(v) }

        // linkedWeekId — crossDBString ref.
        if let v = rec.refs["linkedWeekID"] { dict["linkedWeekId"] = v }

        // Build meals (each with their ingredients).
        let mealDicts: [[String: Any]] = meals.map { mealRec in
            let ings = ingredientsByMeal[mealRec.recordName] ?? []
            return mealDict(mealRec, ingredients: ings)
        }
        dict["meals"] = mealDicts

        // Build attendees — guest nested struct NOT populated here (caller resolves from GuestRepository).
        let attendeeDicts: [[String: Any]] = attendees.map { attendeeDict($0) }
        dict["attendees"] = attendeeDicts

        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(Event.self, from: jsonData)
    }

    // MARK: - Guest → Record

    /// Map a `Guest` to its .guest record.
    public static func record(from guest: Guest) -> HouseholdRecordValue {
        buildGuestRecord(guest)
    }

    // MARK: - Record → Guest

    /// Reconstruct a `Guest` from its .guest CloudKit record.
    public static func guest(from rec: HouseholdRecordValue) -> Guest {
        let s = rec.scalars
        return Guest(
            guestId: rec.recordName,
            name: string(s, "name") ?? "",
            relationshipLabel: string(s, "relationshipLabel") ?? "",
            dietaryNotes: string(s, "dietaryNotes") ?? "",
            allergies: string(s, "allergies") ?? "",
            ageGroup: string(s, "ageGroup") ?? "adult",
            active: bool(s, "active") ?? true,
            createdAt: date(s, "createdAt") ?? Date(timeIntervalSince1970: 0),
            updatedAt: date(s, "updatedAt") ?? Date()
        )
    }

    // MARK: - Private helpers: domain → records

    private static func buildEventRecord(_ event: Event) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "name", .string(event.name))
        if let v = event.eventDate { scalars["eventDate"] = .date(v) }
        setIfNonEmpty(&scalars, "occasion", event.occasion)
        scalars["attendeeCount"] = .int(event.attendeeCount)
        setIfNonEmpty(&scalars, "notes", event.notes)
        setIfNonEmpty(&scalars, "status", event.status)
        scalars["autoMergeGrocery"] = .bool(event.autoMergeGrocery)
        // manuallyMerged: merge-engine-owned; not on domain Event — omit on forward map;
        // the engine sets it directly on the record when needed.
        scalars["createdAt"] = .date(event.createdAt)
        scalars["updatedAt"] = .date(Date())

        var refs: [String: String] = [:]
        if let weekId = event.linkedWeekId { refs["linkedWeekID"] = weekId }

        return HouseholdRecordValue(type: .event, recordName: event.eventId, scalars: scalars, refs: refs)
    }

    private static func buildMealRecord(_ meal: EventMeal, eventId: String) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "role", .string(meal.role))
        set(&scalars, "recipeName", .string(meal.recipeName))
        if let v = meal.servings { scalars["servings"] = .double(v) }
        scalars["scaleMultiplier"] = .double(meal.scaleMultiplier)
        setIfNonEmpty(&scalars, "notes", meal.notes)
        scalars["sortOrder"] = .int(meal.sortOrder)
        scalars["aiGenerated"] = .bool(meal.aiGenerated)
        scalars["approved"] = .bool(meal.approved)
        // constraintCoverage: [String] → JSON-array string (§B — mirrors tag encoding).
        scalars["constraintCoverage"] = .string(encodeStringArray(meal.constraintCoverage))
        scalars["createdAt"] = .date(meal.createdAt)
        scalars["updatedAt"] = .date(Date())

        var refs: [String: String] = [:]
        refs["event"] = eventId                                   // cascadeParent
        if let rid = meal.recipeId            { refs["recipe"]         = rid }  // setNullInZone
        if let gid = meal.assignedGuestId     { refs["assignedGuest"]  = gid }  // setNullInZone

        return HouseholdRecordValue(type: .eventMeal, recordName: meal.mealId, scalars: scalars, refs: refs)
    }

    private static func buildIngredientRecord(
        _ ing: EventMealIngredient,
        eventMealId: String,
        fallbackIndex: Int
    ) -> HouseholdRecordValue {
        let recordName = ing.ingredientId.isEmpty ? "\(eventMealId)_ing_\(fallbackIndex)" : ing.ingredientId
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "ingredientName", .string(ing.ingredientName))
        // normalizedName: not on EventMealIngredient domain struct — omit on forward map
        if let v = ing.quantity { scalars["quantity"] = .double(v) }
        setIfNonEmpty(&scalars, "unit", ing.unit)
        setIfNonEmpty(&scalars, "prep", ing.prep)
        setIfNonEmpty(&scalars, "category", ing.category)
        setIfNonEmpty(&scalars, "notes", ing.notes)
        scalars["updatedAt"] = .date(Date())

        var refs: [String: String] = [:]
        refs["eventMeal"] = eventMealId                           // cascadeParent
        if let v = ing.baseIngredientId      { refs["baseIngredientID"]       = v }  // crossDBString
        if let v = ing.ingredientVariationId { refs["ingredientVariationID"]  = v }  // crossDBString

        return HouseholdRecordValue(
            type: .eventMealIngredient,
            recordName: recordName,
            scalars: scalars,
            refs: refs
        )
    }

    /// Attendee recordName = `<eventID>_<guestID>` (det key per manifest namePolicy).
    private static func buildAttendeeRecord(_ attendee: EventAttendee, eventId: String) -> HouseholdRecordValue {
        let recordName = "\(eventId)_\(attendee.guestId)"
        var scalars: [String: ScalarValue] = [:]

        scalars["plusOnes"] = .int(attendee.plusOnes)
        scalars["createdAt"] = .date(Date())

        var refs: [String: String] = [:]
        refs["event"] = eventId                   // cascadeParent
        refs["guest"] = attendee.guestId          // setNullInZone

        return HouseholdRecordValue(type: .eventAttendee, recordName: recordName, scalars: scalars, refs: refs)
    }

    private static func buildGuestRecord(_ guest: Guest) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "name", .string(guest.name))
        setIfNonEmpty(&scalars, "relationshipLabel", guest.relationshipLabel)
        setIfNonEmpty(&scalars, "dietaryNotes", guest.dietaryNotes)
        setIfNonEmpty(&scalars, "allergies", guest.allergies)
        setIfNonEmpty(&scalars, "ageGroup", guest.ageGroup)
        scalars["active"] = .bool(guest.active)
        scalars["createdAt"] = .date(guest.createdAt)
        scalars["updatedAt"] = .date(Date())

        return HouseholdRecordValue(type: .guest, recordName: guest.guestId, scalars: scalars, refs: [:])
    }

    // MARK: - Private helpers: records → domain dicts

    private static func mealDict(
        _ rec: HouseholdRecordValue,
        ingredients: [HouseholdRecordValue]
    ) -> [String: Any] {
        let s = rec.scalars
        var d: [String: Any] = [
            "mealId": rec.recordName,
            "role": string(s, "role") ?? "",
            "recipeName": string(s, "recipeName") ?? "",
            "scaleMultiplier": double(s, "scaleMultiplier") ?? 1.0,
            "notes": string(s, "notes") ?? "",
            "sortOrder": int(s, "sortOrder") ?? 0,
            "aiGenerated": bool(s, "aiGenerated") ?? false,
            "approved": bool(s, "approved") ?? false,
            // constraintCoverage (§B) — decode from JSON-array string.
            "constraintCoverage": decodeStringArray(string(s, "constraintCoverage") ?? ""),
            // Derived (§D) — not echoed; caller supplies via EventRepository.
            "ingredients": ingredients.map { ingredientDict($0) },
        ]

        d["createdAt"] = iso8601(date(s, "createdAt") ?? Date(timeIntervalSince1970: 0))
        d["updatedAt"] = iso8601(date(s, "updatedAt") ?? Date())

        if let v = double(s, "servings") { d["servings"] = v }
        if let rid = rec.refs["recipe"]        { d["recipeId"]       = rid }
        if let gid = rec.refs["assignedGuest"] { d["assignedGuestId"] = gid }

        return d
    }

    private static func ingredientDict(_ rec: HouseholdRecordValue) -> [String: Any] {
        let s = rec.scalars
        var d: [String: Any] = [
            "ingredientId": rec.recordName,
            "ingredientName": string(s, "ingredientName") ?? "",
            "unit": string(s, "unit") ?? "",
            "prep": string(s, "prep") ?? "",
            "category": string(s, "category") ?? "",
            "notes": string(s, "notes") ?? "",
        ]
        if let v = double(s, "quantity") { d["quantity"] = v }
        if let v = rec.refs["baseIngredientID"]       { d["baseIngredientId"]      = v }
        if let v = rec.refs["ingredientVariationID"]  { d["ingredientVariationId"] = v }
        return d
    }

    private static func attendeeDict(_ rec: HouseholdRecordValue) -> [String: Any] {
        let s = rec.scalars
        let guestId = rec.refs["guest"] ?? ""
        // guest nested struct (§D): not populated here — caller resolves from GuestRepository.
        // EventAttendee requires a guest struct; provide a minimal placeholder that the
        // repository will replace on reassembly.
        let guestPlaceholder: [String: Any] = [
            "guestId": guestId,
            "name": "",
            "relationshipLabel": "",
            "dietaryNotes": "",
            "allergies": "",
            "ageGroup": "adult",
            "active": true,
            "createdAt": iso8601(Date(timeIntervalSince1970: 0)),
            "updatedAt": iso8601(Date(timeIntervalSince1970: 0)),
        ]
        return [
            "guestId": guestId,
            "plusOnes": int(s, "plusOnes") ?? 0,
            "guest": guestPlaceholder,
        ]
    }

    // MARK: - String-array serialisation (§B — mirrors RecipeRecordMapper.encodeTags)

    static func encodeStringArray(_ arr: [String]) -> String {
        let data = try! JSONEncoder().encode(arr)
        return String(data: data, encoding: .utf8)!
    }

    static func decodeStringArray(_ s: String) -> [String] {
        guard !s.isEmpty,
              let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }

    // MARK: - Scalar accessors

    private static func string(_ scalars: [String: ScalarValue], _ key: String) -> String? {
        if case let .string(v) = scalars[key] { return v }
        return nil
    }

    private static func int(_ scalars: [String: ScalarValue], _ key: String) -> Int? {
        if case let .int(v) = scalars[key] { return v }
        return nil
    }

    private static func double(_ scalars: [String: ScalarValue], _ key: String) -> Double? {
        if case let .double(v) = scalars[key] { return v }
        return nil
    }

    private static func bool(_ scalars: [String: ScalarValue], _ key: String) -> Bool? {
        if case let .bool(v) = scalars[key] { return v }
        return nil
    }

    private static func date(_ scalars: [String: ScalarValue], _ key: String) -> Date? {
        if case let .date(v) = scalars[key] { return v }
        return nil
    }

    private static func set(_ scalars: inout [String: ScalarValue], _ key: String, _ value: ScalarValue) {
        scalars[key] = value
    }

    private static func setIfNonEmpty(_ scalars: inout [String: ScalarValue], _ key: String, _ value: String) {
        if !value.isEmpty { scalars[key] = .string(value) }
    }

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
