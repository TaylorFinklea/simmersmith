#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync

// NOTE: GroceryMerge is intentionally NOT imported here. Its `GroceryItem` would collide with the
// SimmerSmithKit domain `GroceryItem` (the module name `SimmerSmithKit` is shadowed by an enum of
// the same name, so the domain type can't be module-qualified to break the tie). The merge type is
// reached only through module-qualified `GroceryMerge.GroceryItem` (valid for a linked module
// without an explicit import), leaving bare `GroceryItem` to mean the domain row unambiguously.

// SP-C Task 3 — WeekRepository: week + meal + side CRUD backed by the CloudKit household store.
//
// Mirrors RecipeRepository. Reads reassemble a WeekSnapshot from the .week record plus its
// .weekMeal children and each meal's .weekMealSide grandchildren (spec §4); writes decompose a
// WeekSnapshot / meal-update set back into those records, diffing children the same way
// RecipeRepository diffs ingredients/steps (save changed + new, explicit per-record delete for
// removed — NOT cascade, which is only for whole-week delete).
//
// The week aggregate reassembly (reload):
//   1. Gather every .week record; for each, gather its .weekMeal children (filter by the `week`
//      ref) and each meal's .weekMealSide children (filter by the `weekMeal` ref).
//   2. Resolve each meal's denormalized `ingredients` from the recipe's own .recipeIngredient
//      records (the WeekRecordMapper deliberately does NOT store them — they're derived).
//   3. Pull the week's GroceryItem records (filter by the `weekID` string field) via GroceryCodec
//      and convert to the domain GroceryItem shape so the snapshot carries the live grocery list.
//   4. Hand the records to WeekRecordMapper.week(...) to JSON-round-trip into a WeekSnapshot.
//   Derived fields (nutrition, staged/feedback/export counts, meal macros) are nil/0/[] per §5 —
//   a nutrition pass recomputes them client-side later.
//
// Navigation: weeks are keyed by `weekStart`. `week(forStart:)` scans the store's .week records
// for the one whose weekStart lands on the requested day (UTC day granularity, matching the
// server's date-only week_start). `currentWeek()` is the caller's concern (AppState) — this
// repository just exposes the keyed lookup + the full sorted list.
//
// GroceryItem regen / check-state / dedupe live in GroceryRepository; this repository only
// reads grocery rows into the snapshot for display.
//
// Headless test note (mirrors RecipeRepository): the child-diff logic lives at the
// engine.save/delete call site (not a pure value transform), and HouseholdSyncEngine can't be
// instantiated without iCloud, so verification is deferred to on-device (spec §8).

@MainActor
@Observable
final class WeekRepository {

    // MARK: - Observable state

    private(set) var weeks: [WeekSnapshot] = []

    /// Set when `sendUntilDrained()` fails on any write path (mirrors RecipeRepository).
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Observe storeRevision

    func startObserving() {
        observeRevision()
    }

    private func observeRevision() {
        withObservationTracking {
            _ = session.storeRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
                self?.observeRevision()
            }
        }
    }

    // MARK: - Read

    /// Recompute `weeks` from the local store. Reassembles each `.week` record into a full
    /// `WeekSnapshot` (meals + sides + grocery), sorted newest-week-first by weekStart.
    func reload() {
        let store = session.store

        // Index children once for the whole pass (avoid O(weeks × records) re-scans).
        let mealRecords = store.records(ofType: HouseholdRecordType.weekMeal.recordTypeName)
        let sideRecords = store.records(ofType: HouseholdRecordType.weekMealSide.recordTypeName)
        let ingredientRecords = store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName)
        let groceryRecords = store.records(ofType: GroceryCodec.recordType)

        // Group meals by their parent week ref.
        var mealsByWeek: [String: [CKRecord]] = [:]
        for rec in mealRecords {
            let weekID = refName(rec["week"])
            guard !weekID.isEmpty else { continue }
            mealsByWeek[weekID, default: []].append(rec)
        }

        // Group sides by their parent weekMeal ref.
        var sidesByMeal: [String: [CKRecord]] = [:]
        for rec in sideRecords {
            let mealID = refName(rec["weekMeal"])
            guard !mealID.isEmpty else { continue }
            sidesByMeal[mealID, default: []].append(rec)
        }

        // Group recipe-ingredient records by their parent recipe ref (for meal denormalization).
        var ingredientsByRecipe: [String: [HouseholdRecordValue]] = [:]
        for rec in ingredientRecords {
            let value = HouseholdRecordCodec.decode(rec, as: .recipeIngredient)
            if let recipeID = value.refs["recipe"] {
                ingredientsByRecipe[recipeID, default: []].append(value)
            }
        }

        // Group grocery rows by their weekID string field.
        var groceryByWeek: [String: [GroceryItem]] = [:]
        for rec in groceryRecords {
            // Hide tombstones from the snapshot's grocery list (the server omits isUserRemoved
            // from the regular week payload — match that here).
            guard (rec["isUserRemoved"] as? Int ?? 0) == 0 else { continue }
            let weekID = rec["weekID"] as? String ?? ""
            guard !weekID.isEmpty else { continue }
            groceryByWeek[weekID, default: []].append(domainGrocery(fromRecord: rec))
        }

        var result: [WeekSnapshot] = []
        for weekRecord in store.records(ofType: HouseholdRecordType.week.recordTypeName) {
            let weekID = weekRecord.recordID.recordName
            let weekValue = HouseholdRecordCodec.decode(weekRecord, as: .week)

            // Sort meals by mealDate then slot for a stable planner order.
            let mealRecs = (mealsByWeek[weekID] ?? []).sorted { a, b in
                let da = (a["mealDate"] as? Date) ?? .distantPast
                let db = (b["mealDate"] as? Date) ?? .distantPast
                if da != db { return da < db }
                return (a["slot"] as? String ?? "") < (b["slot"] as? String ?? "")
            }

            // Decode meals to record values; attach resolved ingredients into each meal record value.
            var mealValues: [HouseholdRecordValue] = []
            var sidesByMealValue: [String: [HouseholdRecordValue]] = [:]
            var ingredientsByMeal: [String: [RecipeIngredient]] = [:]
            for mealRec in mealRecs {
                let mealValue = HouseholdRecordCodec.decode(mealRec, as: .weekMeal)
                let mealID = mealValue.recordName
                mealValues.append(mealValue)

                // Sides for this meal, sorted by sortOrder.
                let mealSideRecs = (sidesByMeal[mealID] ?? []).sorted {
                    ($0["sortOrder"] as? Int ?? 0) < ($1["sortOrder"] as? Int ?? 0)
                }
                sidesByMealValue[mealID] = mealSideRecs.map { HouseholdRecordCodec.decode($0, as: .weekMealSide) }

                // Resolve denormalized ingredients from the meal's recipe.
                if let recipeID = mealValue.refs["recipe"] {
                    let ingValues = ingredientsByRecipe[recipeID] ?? []
                    ingredientsByMeal[mealID] = ingValues.map { ingredient(from: $0) }
                }
            }

            // Reassemble the snapshot (ingredients are injected post-mapper since the mapper leaves
            // meal.ingredients as []).
            let snapshot = assembleSnapshot(
                weekValue: weekValue,
                meals: mealValues,
                sidesByMeal: sidesByMealValue,
                ingredientsByMeal: ingredientsByMeal,
                grocery: groceryByWeek[weekID] ?? []
            )
            result.append(snapshot)
        }

        // Newest week first (matches a calendar default).
        result.sort { $0.weekStart > $1.weekStart }
        weeks = result
    }

    /// Read-only: the week's user-removed (tombstoned) grocery rows — the counterpart of the
    /// `isUserRemoved` filter `reload()` applies when assembling the snapshot's live list above.
    /// Feeds GroceryArchiveSheet's "Removed items" sheet, which needs to see the rows the regular
    /// snapshot hides.
    func removedGroceryItems(weekID: String) -> [GroceryItem] {
        session.store.records(ofType: GroceryCodec.recordType)
            .filter { rec in
                (rec["weekID"] as? String) == weekID && (rec["isUserRemoved"] as? Int ?? 0) != 0
            }
            .map(domainGrocery(fromRecord:))
    }

    /// Find the week whose weekStart lands on the same UTC day as `start`, or nil.
    func week(forStart start: Date) -> WeekSnapshot? {
        let target = Self.utcDayKey(start)
        return weeks.first { Self.utcDayKey($0.weekStart) == target }
    }

    /// Look a week up by its record name (weekId).
    func week(forId weekID: String) -> WeekSnapshot? {
        weeks.first { $0.weekId == weekID }
    }

    /// The week covering `day`. PREFERS the Monday-aligned (canonical) week so a stray
    /// mis-aligned week (e.g. a pre-fix Friday-started artifact still syncing) never wins
    /// over the real Monday week; falls back to any overlapping week when none is aligned.
    func week(covering day: Date) -> WeekSnapshot? {
        weeks.first { WeekBoundary.weekContains($0.weekStart, day: day) && WeekBoundary.isMonday($0.weekStart) }
            ?? weeks.first { WeekBoundary.weekContains($0.weekStart, day: day) }
    }

    /// Ensure the store has a week for today's 7-day period — returning the existing one
    /// when present, or creating it on-device when not — and return it. Idempotent: when a
    /// week already covers today NOTHING is written. This is the CloudKit cutover's
    /// current-week owner: the planner no longer depends on Fly to mint the active week.
    ///
    /// A newly-created week's start preserves the existing weeks' 7-day phase (anchored to
    /// the newest week), or anchors to today's UTC day when the store has no weeks yet.
    @discardableResult
    func ensureCurrentWeek(today: Date = Date(), preferredStart: Date? = nil) -> WeekSnapshot? {
        // The canonical start for today's week: the carry-over period when given, else
        // this week's Monday (weeks run Monday–Sunday).
        let target: Date
        if let preferredStart, WeekBoundary.weekContains(preferredStart, day: today) {
            // Caller wants to preserve a specific period (e.g. carrying over an in-memory
            // week's meals, whose dates must line up with the new week's day grid).
            target = WeekBoundary.utcCalendar.startOfDay(for: preferredStart)
        } else {
            target = WeekBoundary.mondayStart(containing: today)
        }
        // Reuse the week that starts ON the target day. A mis-aligned week that merely
        // OVERLAPS today (a stray Friday-started artifact) does NOT count — so the correct
        // canonical week is created even while that stray still exists, and resolution
        // (week(covering:)) then prefers it.
        if let existing = weeks.first(where: { WeekBoundary.isSameUTCDay($0.weekStart, target) }) {
            return existing
        }
        let weekEnd = WeekBoundary.utcCalendar.date(byAdding: .day, value: 7, to: target) ?? target
        // Deterministic record name keyed on the period's start, so two devices that both
        // auto-create the same period offline produce the SAME record (one week, not two).
        let recordName = "week-" + Self.utcDayKey(target)
        return createWeek(weekStart: target, weekEnd: weekEnd, recordName: recordName)
    }

    // MARK: - Reassembly helpers

    /// Run the WeekRecordMapper, then inject each meal's resolved `ingredients` (the mapper
    /// leaves them empty by design — they're derived, not stored).
    private func assembleSnapshot(
        weekValue: HouseholdRecordValue,
        meals: [HouseholdRecordValue],
        sidesByMeal: [String: [HouseholdRecordValue]],
        ingredientsByMeal: [String: [RecipeIngredient]],
        grocery: [GroceryItem]
    ) -> WeekSnapshot {
        let base = WeekRecordMapper.week(
            from: weekValue,
            meals: meals,
            sidesByMeal: sidesByMeal,
            groceryItems: grocery
        )
        // If no meal carries resolved ingredients, the mapper output is already complete.
        guard ingredientsByMeal.values.contains(where: { !$0.isEmpty }) else { return base }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard var dict = (try? encoder.encode(base))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
            var mealDicts = dict["meals"] as? [[String: Any]]
        else { return base }

        for index in mealDicts.indices {
            guard let mealID = mealDicts[index]["mealId"] as? String,
                  let ings = ingredientsByMeal[mealID], !ings.isEmpty,
                  let ingData = try? encoder.encode(ings),
                  let ingDicts = try? JSONSerialization.jsonObject(with: ingData) as? [[String: Any]]
            else { continue }
            mealDicts[index]["ingredients"] = ingDicts
        }
        dict["meals"] = mealDicts

        guard let patched = (try? JSONSerialization.data(withJSONObject: dict))
            .flatMap({ try? decoder.decode(WeekSnapshot.self, from: $0) })
        else { return base }
        return patched
    }

    /// Build a domain `RecipeIngredient` from a decoded `.recipeIngredient` record value.
    private func ingredient(from value: HouseholdRecordValue) -> RecipeIngredient {
        RecipeIngredient(
            ingredientId: value.recordName,
            ingredientName: scalarString(value, "ingredientName") ?? "",
            normalizedName: scalarString(value, "normalizedName"),
            baseIngredientId: value.refs["baseIngredientID"],
            ingredientVariationId: value.refs["ingredientVariationID"],
            resolutionStatus: scalarString(value, "resolutionStatus") ?? "unresolved",
            quantity: scalarDouble(value, "quantity"),
            unit: scalarString(value, "unit") ?? "",
            prep: scalarString(value, "prep") ?? "",
            category: scalarString(value, "category") ?? "",
            notes: scalarString(value, "notes") ?? ""
        )
    }

    /// Decode a `GroceryItem` CKRecord (via GroceryCodec) and convert it into the SimmerSmithKit
    /// domain grocery row (the snapshot's grocery shape) via JSON. Takes a `CKRecord` rather than
    /// the merge value type so the GroceryMerge.GroceryItem type never appears in a signature —
    /// naming it would require `import GroceryMerge`, whose `GroceryItem` collides with the domain
    /// one (and the module name is shadowed by an enum, so the domain type can't be qualified).
    /// Decode + convert a GroceryItem CKRecord into the domain grocery row. The codec output type
    /// is inferred (never named), sidestepping the GroceryItem name collision described above. The
    /// merge value type carries logical clocks (Int) for checkedAt; the domain row carries an ISO
    /// date — we drop the clock (display needs only the bool, not the wall-clock check time).
    private func domainGrocery(fromRecord record: CKRecord) -> GroceryItem {
        let item = GroceryCodec.decode(record)
        var d: [String: Any] = [
            "groceryItemId": item.recordName,
            "ingredientName": item.ingredientName,
            "normalizedName": item.normalizedName,
            "resolutionStatus": item.resolutionStatus,
            "unit": item.unit,
            "quantityText": item.quantityText,
            "category": item.category,
            "sourceMeals": item.sourceMeals,
            "notes": item.notes,
            "reviewFlag": item.reviewFlag,
            "isUserAdded": item.isUserAdded,
            "isUserRemoved": item.isUserRemoved,
            "isChecked": item.check.isChecked,
            "storeLabel": item.storeLabel,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "retailerPrices": [[String: Any]](),
        ]
        if let v = item.baseIngredientID { d["baseIngredientId"] = v }
        if let v = item.ingredientVariationID { d["ingredientVariationId"] = v }
        if let v = item.totalQuantity { d["totalQuantity"] = v }
        if let v = item.quantityOverride { d["quantityOverride"] = v }
        if let v = item.unitOverride { d["unitOverride"] = v }
        if let v = item.notesOverride { d["notesOverride"] = v }
        if let v = item.eventQuantity { d["eventQuantity"] = v }
        if let v = item.check.by { d["checkedByUserId"] = v }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try! JSONSerialization.data(withJSONObject: d)
        return try! decoder.decode(GroceryItem.self, from: data)
    }

    // MARK: - Write: meals

    /// Replace a week's meals (M-style batch update). Diffs the incoming `MealUpdateRequest` set
    /// against the store's current `.weekMeal` children for this week: upserts changed/new meals
    /// (preserving the server change tag when present), explicitly deletes removed meals
    /// (NOT cascade — cascade is only for a whole-week delete). Returns the reloaded snapshot.
    ///
    /// `knownMealIDs` is a BASELINE-AWARE DELETE guard (simmersmith-eky): the mealIds present in
    /// the caller's SOURCE snapshot (the one it built `meals` from). A store meal is only ever a
    /// deletion candidate if the caller both knew about it (in `knownMealIDs`) and dropped it (not
    /// in `meals`) — a concurrent write the caller's snapshot never saw is always kept. See
    /// `WeekMealDeletePolicy`.
    @discardableResult
    func saveWeekMeals(weekID: String, meals: [MealUpdateRequest], knownMealIDs: Set<String>) -> WeekSnapshot? {
        let store = session.store
        let zoneID = session.zoneID

        // Guard: the `.week` parent MUST exist before we write any `.weekMeal` children.
        // Without this, a stale/phantom weekID — e.g. a Fly-sourced `currentWeek` whose
        // record was never imported into this CloudKit store — would create ORPHAN meal
        // records that sync but belong to no week, and the caller would only learn of it
        // via a confusing "Week not found" AFTER the write. Fail fast, write nothing.
        // (Mirrors approveWeek's parent check.)
        guard store.record(for: CKRecord.ID(recordName: weekID, zoneID: zoneID)) != nil else {
            let knownWeekIDs = weeks.map { $0.weekId }
            let weekCount = store.records(ofType: HouseholdRecordType.week.recordTypeName).count
            // Diagnostic disambiguates phantom-id (weekCount 0 / id absent) from a
            // wrong/foreign zone (weekCount > 0 with other ids) on the next repro.
            print("[WeekRepository] saveWeekMeals: no .week parent for weekID=\(weekID); " +
                  "weekCount=\(weekCount); zone=\(zoneID.zoneName); knownWeekIDs=\(knownWeekIDs)")
            return nil
        }

        // Existing meal record names for this week.
        let existingNames = Set(
            store.records(ofType: HouseholdRecordType.weekMeal.recordTypeName)
                .filter { refName($0["week"]) == weekID }
                .map { $0.recordID.recordName }
        )

        var newNames = Set<String>()
        for request in meals {
            let mealID = request.mealId ?? UUID().uuidString
            newNames.insert(mealID)
            upsertRecord(mealRecordValue(request, mealID: mealID, weekID: weekID))
        }

        // Delete meals no longer present (individual delete; sides cascade with their parent meal).
        // Baseline-aware: only delete ids the caller's snapshot knew about AND dropped.
        for name in WeekMealDeletePolicy.toDelete(existing: existingNames, desired: newNames, known: knownMealIDs) {
            session.engine.deleteCascading(CKRecord.ID(recordName: name, zoneID: zoneID))
        }

        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    /// Create a new week record (no meals yet). Mirrors the server `createWeek`. Returns the
    /// reloaded snapshot.
    @discardableResult
    func createWeek(weekStart: Date, weekEnd: Date, notes: String = "", recordName: String? = nil) -> WeekSnapshot? {
        // A caller may pin a deterministic record name (see ensureCurrentWeek) so two
        // devices auto-creating the same period collide into ONE record instead of two.
        let weekID = recordName ?? UUID().uuidString
        var scalars: [String: ScalarValue] = [
            "weekStart": .date(weekStart),
            "weekEnd": .date(weekEnd),
            "status": .string("staging"),
            "updatedAt": .date(Date()),
        ]
        if !notes.isEmpty { scalars["notes"] = .string(notes) }
        upsertRecord(HouseholdRecordValue(type: .week, recordName: weekID, scalars: scalars, refs: [:]))
        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    /// Delete a week and (cascading) its meals/sides/grocery. Used to self-heal an empty
    /// mis-aligned auto-created week (see AppState.ensureCurrentCloudKitWeek).
    func deleteWeek(weekID: String) {
        session.engine.deleteCascading(CKRecord.ID(recordName: weekID, zoneID: session.zoneID))
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    /// Approve a week: stamp `status=approved` + `approvedAt`. Returns the reloaded snapshot.
    @discardableResult
    func approveWeek(weekID: String) -> WeekSnapshot? {
        guard let existing = session.store.record(
            for: CKRecord.ID(recordName: weekID, zoneID: session.zoneID)) else { return nil }
        existing["status"] = "approved" as CKRecordValue
        existing["approvedAt"] = Date() as CKRecordValue
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    // MARK: - Write: sides

    /// Add a side to a meal. Returns the reloaded snapshot.
    @discardableResult
    func addMealSide(
        weekID: String,
        mealID: String,
        name: String,
        recipeID: String? = nil,
        recipeName: String? = nil,
        notes: String = ""
    ) -> WeekSnapshot? {
        // sortOrder = max existing side sortOrder for this meal + 1.
        let existingSides = session.store.records(ofType: HouseholdRecordType.weekMealSide.recordTypeName)
            .filter { refName($0["weekMeal"]) == mealID }
        let nextSort = (existingSides.compactMap { $0["sortOrder"] as? Int }.max() ?? -1) + 1

        let side = WeekMealSide(
            sideId: UUID().uuidString,
            weekMealId: mealID,
            recipeId: recipeID,
            recipeName: recipeName,
            name: name,
            notes: notes,
            sortOrder: nextSort,
            updatedAt: Date()
        )
        upsertRecord(sideRecordValue(side))
        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    /// Patch an existing side's name / notes / recipe link. Returns the reloaded snapshot.
    @discardableResult
    func updateMealSide(
        weekID: String,
        sideID: String,
        name: String? = nil,
        notes: String? = nil,
        recipeID: SidePatch<String>? = nil,
        recipeName: SidePatch<String>? = nil
    ) -> WeekSnapshot? {
        guard let existing = session.store.record(
            for: CKRecord.ID(recordName: sideID, zoneID: session.zoneID)) else { return nil }
        if let name { existing["name"] = name as CKRecordValue }
        if let notes { existing["notes"] = notes as CKRecordValue }
        switch recipeName {
        case .set(let v): existing["recipeName"] = v as CKRecordValue
        case .clear: existing["recipeName"] = nil
        case nil: break
        }
        switch recipeID {
        case .set(let v):
            existing["recipe"] = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: v, zoneID: session.zoneID), action: .none)
        case .clear: existing["recipe"] = nil
        case nil: break
        }
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    /// Delete a side. Returns the reloaded snapshot.
    @discardableResult
    func deleteMealSide(weekID: String, sideID: String) -> WeekSnapshot? {
        let id = CKRecord.ID(recordName: sideID, zoneID: session.zoneID)
        guard session.store.record(for: id) != nil else { return week(forId: weekID) }
        session.engine.delete(id)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return week(forId: weekID)
    }

    /// A three-state patch for optional side fields: set a value, clear it, or leave unchanged.
    enum SidePatch<Value> {
        case set(Value)
        case clear
    }

    // MARK: - Record builders

    private func mealRecordValue(_ request: MealUpdateRequest, mealID: String, weekID: String) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "dayName": .string(request.dayName),
            "mealDate": .date(request.mealDate),
            "slot": .string(request.slot),
            "recipeName": .string(request.recipeName),
            "scaleMultiplier": .double(request.scaleMultiplier),
            "approved": .bool(request.approved),
            "updatedAt": .date(Date()),
        ]
        if let v = request.servings { scalars["servings"] = .double(v) }
        if !request.notes.isEmpty { scalars["notes"] = .string(request.notes) }

        var refs: [String: String] = ["week": weekID]
        if let recipeID = request.recipeId { refs["recipe"] = recipeID }

        return HouseholdRecordValue(type: .weekMeal, recordName: mealID, scalars: scalars, refs: refs)
    }

    private func sideRecordValue(_ side: WeekMealSide) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [
            "name": .string(side.name),
            "sortOrder": .int(side.sortOrder),
            "updatedAt": .date(side.updatedAt),
        ]
        if let v = side.recipeName, !v.isEmpty { scalars["recipeName"] = .string(v) }
        if !side.notes.isEmpty { scalars["notes"] = .string(side.notes) }

        var refs: [String: String] = ["weekMeal": side.weekMealId]
        if let recipeID = side.recipeId { refs["recipe"] = recipeID }

        return HouseholdRecordValue(type: .weekMealSide, recordName: side.sideId, scalars: scalars, refs: refs)
    }

    // MARK: - Write helpers (mirror RecipeRepository.upsertRecord)

    private func upsertRecord(_ value: HouseholdRecordValue) {
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
            session.engine.save(existing)
        } else {
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
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
            print("[WeekRepository] sendUntilDrained failed: \(error)")
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

    private static func utcDayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
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
