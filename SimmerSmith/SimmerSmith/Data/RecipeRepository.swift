#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync

// SP-C Task 4 — RecipeRepository: recipe CRUD + images backed by the CloudKit household store.
//
// Reads/writes recipes via the HouseholdLocalStore (source of truth while online), mapping
// CKRecord ↔ RecipeSummary through HouseholdRecordCodec + RecipeRecordMapper.
//
// Upsert idiom (mirrors EventMergeAdapter): if the record already exists in the store,
// encode into the existing CKRecord (preserving the server change tag) and save. Otherwise
// save a freshly constructed record. This prevents change-tag conflicts on concurrent edits.
//
// Child-diff idiom (save + delete):
//   On save, the old child record set is compared to the new one by recordName.
//   New and modified children are saved; removed children are explicitly engine.delete'd
//   (NOT cascaded — cascade is only for whole-recipe delete). This ensures CloudKit sees
//   individual deletes and the local store stays consistent.
//
// Derived fields computed in reload() from the full in-memory recipe set:
//   - isVariant: recipe.baseRecipeId != nil
//   - variantCount: count of recipes whose baseRecipeId == this recipe's recipeId
//   - sourceRecipeCount: always 0 (derived; repository recomputes — never fabricate)
//   - daysSinceLastUsed: Calendar.current.dateComponents from lastUsed to now (nil when absent)
//   - familyDaysSinceLastUsed: same from familyLastUsed (always nil — not stored in CloudKit records)
//
// Images: RecipeImageCodec.decode/encode via RecipeImageCodec.recordName(forRecipe:).
// The `rimg:<recipeId>` record carries a CKAsset; imageBytes() returns nil when the
// asset isn't downloaded yet (assetNotDownloaded) rather than crashing.
//
// Headless test: HouseholdLocalStore initializes without a CloudKit account (it's pure
// in-memory), but HouseholdSyncEngine requires a CKDatabase + zone — it cannot be
// instantiated without iCloud. The child-diff logic lives at the engine.save/delete
// call site (not in a pure value transform), so no headless test is added; this is
// deferred to on-device verification in Task 7.

// SP-D 990.4.1 — one memory log entry attached to a recipe (Fly recipe_memories, mirrored onto
// the household-zone RecipeMemory manifest record). `hasPhoto` mirrors RecipeSummary.hasImage:
// the photo itself is a separate RecipeMemoryImage CKAsset, fetched via `memoryPhotoBytes(_:)`,
// never inlined here. Named RecipeMemory*-prefixed to stay distinct from Recipe's legacy
// scalar `memories` field (a different, pre-existing free-text concept).
struct RecipeMemoryEntry: Identifiable, Equatable {
    let id: String
    var body: String
    var createdAt: Date
    var hasPhoto: Bool
}

@MainActor
@Observable
final class RecipeRepository {

    // MARK: - Observable state

    private(set) var recipes: [RecipeSummary] = []

    /// Bumped at the end of every `reload()` — i.e., on each household-store change
    /// the revisionReloader observes (plus explicit CRUD reloads). Views that read
    /// derived-but-not-mirrored store state key refreshes off this: a memory photo's
    /// CKAsset arriving after first render never changes `recipes`, so observing it
    /// is the only signal that a retry might now succeed. (simmersmith-zgt)
    private(set) var storeGeneration = 0

    /// Set when `sendUntilDrained()` fails on any write path. Task 5 / the UI can
    /// observe this to surface a sync-error banner and retry button.
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Observe storeRevision

    /// Call from the owning view / AppState after init to wire the revision observer.
    /// Uses `ObservationReloader` (simmersmith-7mb) to trigger `reload()` whenever
    /// `session.storeRevision` changes, re-registering before each reload so a bump during
    /// an in-flight reload is never missed.
    @ObservationIgnored
    private lazy var revisionReloader = ObservationReloader(
        track: { [weak self] in _ = self?.session.storeRevision },
        reload: { [weak self] in self?.reload() }
    )

    func startObserving() {
        revisionReloader.start()
    }

    // MARK: - Read

    /// Recompute `recipes` from the local store. Gathers all `.recipe` records, maps
    /// each to a `RecipeSummary` via the codec + mapper, computes derived fields from
    /// the full set, then sorts by name (matching `AppState.upsertRecipe`'s sort order).
    func reload() {
        let store = session.store
        let zoneID = session.zoneID

        // 1. Gather all recipe records and decode them.
        let recipeRecords = store.records(ofType: HouseholdRecordType.recipe.recordTypeName)
        let ingredientRecords = store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName)
        let stepRecords = store.records(ofType: HouseholdRecordType.recipeStep.recordTypeName)
        let imageRecordNames = Set(
            store.records(ofType: RecipeImageCodec.recordType)
                .map { $0.recordID.recordName }
        )

        // Group children by their parent recipe ref.
        var ingredientsByRecipe: [String: [HouseholdRecordValue]] = [:]
        for record in ingredientRecords {
            let value = HouseholdRecordCodec.decode(record, as: .recipeIngredient)
            if let recipeID = value.refs["recipe"] {
                ingredientsByRecipe[recipeID, default: []].append(value)
            }
        }

        var stepsByRecipe: [String: [HouseholdRecordValue]] = [:]
        for record in stepRecords {
            let value = HouseholdRecordCodec.decode(record, as: .recipeStep)
            if let recipeID = value.refs["recipe"] {
                stepsByRecipe[recipeID, default: []].append(value)
            }
        }

        // 2. Map each recipe record to a RecipeSummary (derived fields are nil/0 at this point).
        var mapped: [RecipeSummary] = []
        for record in recipeRecords {
            let recipeValue = HouseholdRecordCodec.decode(record, as: .recipe)
            let recipeID = recipeValue.recordName
            let hasImage = imageRecordNames.contains(RecipeImageCodec.recordName(forRecipe: recipeID))
            let ingredients = ingredientsByRecipe[recipeID] ?? []
            let steps = stepsByRecipe[recipeID] ?? []
            let summary = RecipeRecordMapper.recipe(
                from: recipeValue,
                ingredients: ingredients,
                steps: steps,
                hasImage: hasImage
            )
            mapped.append(summary)
        }

        // 3. Compute derived fields from the full set.
        let now = Date()
        let calendar = Calendar.current

        // Build the variant-count index: recipeId → number of variants pointing at it.
        var variantCountByBase: [String: Int] = [:]
        for r in mapped {
            if let base = r.baseRecipeId {
                variantCountByBase[base, default: 0] += 1
            }
        }

        // Re-map with computed derived fields via JSON round-trip (RecipeSummary has no
        // memberwise init — same trick the mapper uses).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var result: [RecipeSummary] = []
        result.reserveCapacity(mapped.count)
        for r in mapped {
            // daysSinceLastUsed from lastUsed.
            let daysSince: Int? = r.lastUsed.map {
                max(0, calendar.dateComponents([.day], from: $0, to: now).day ?? 0)
            }
            // familyDaysSinceLastUsed: not stored in CloudKit; always nil.
            // variantCount.
            let varCount = variantCountByBase[r.recipeId] ?? 0
            // isVariant.
            let isVariant = r.baseRecipeId != nil

            if daysSince == nil && varCount == 0 && !isVariant {
                // Nothing changed from the mapper defaults; use as-is.
                result.append(r)
                continue
            }

            // Patch only the fields the mapper left as defaults.
            guard var dict = (try? encoder.encode(r)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
                result.append(r)
                continue
            }
            dict["isVariant"] = isVariant
            dict["variantCount"] = varCount
            if let d = daysSince { dict["daysSinceLastUsed"] = d }

            guard let patched = (try? JSONSerialization.data(withJSONObject: dict)).flatMap({ try? decoder.decode(RecipeSummary.self, from: $0) }) else {
                result.append(r)
                continue
            }
            result.append(patched)
        }

        // Sort by name (matches AppState.upsertRecipe's sort).
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        recipes = result
        storeGeneration += 1
    }

    // MARK: - Write helpers

    /// Upsert a household record: encode into the existing CKRecord when present
    /// (preserving the server change tag), otherwise save a fresh one.
    private func upsertRecord(_ value: HouseholdRecordValue) -> Bool {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            // Encode into the server-authoritative record to preserve the change tag.
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

    private func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v):    return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v):   return v as CKRecordValue
        case .bool(let v):   return (v ? 1 : 0) as CKRecordValue
        }
    }

    /// Drain pending CloudKit writes. Logs failures and surfaces them via `lastSyncError`
    /// so Task 5 / the UI can observe and offer a retry. Does NOT throw — the caller's
    /// local write already succeeded; this is a background network flush.
    ///
    /// `internal` (not private) so the backfill batch path in AppState+Recipes can
    /// spawn one drain task after staging all images (AI-4 review fix F3).
    func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[RecipeRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }

    // MARK: - Save

    /// Save a `RecipeDraft`: build a `RecipeSummary`, map to CloudKit records, diff and
    /// apply child changes, reload, and return the reloaded summary. Kicks
    /// `engine.sendUntilDrained()` in a background task after writes. Throws if the
    /// draft→summary encoding fails (guards against `RecipeSummary` Codable contract drift).
    @discardableResult
    func save(_ draft: RecipeDraft) throws -> RecipeSummary {
        // Build a RecipeSummary from the draft (the mapper needs a RecipeSummary).
        let recipeID = draft.recipeId ?? UUID().uuidString
        let summary = try draftToSummary(draft, recipeID: recipeID)

        // Map to CloudKit records.
        let mapped = RecipeRecordMapper.records(from: summary)

        let childDeletions = childDeletionIDs(
            recipeID: recipeID,
            newIngredients: mapped.ingredients,
            newSteps: mapped.steps
        )
        try authorizeChildDeletions(childDeletions)

        // Upsert the recipe record only after a known child-delete denial has failed closed.
        guard upsertRecord(mapped.recipe) else {
            throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
        }

        // Diff children: compare store's current children vs incoming.
        try diffAndApplyChildren(
            newIngredients: mapped.ingredients,
            newSteps: mapped.steps,
            deletions: childDeletions
        )

        // Reload the in-memory list.
        reload()

        // Push to CloudKit in background.
        Task { [weak self] in
            await self?.drainSync()
        }

        // Return the reloaded summary (or fall back to the mapped one if not found yet).
        return recipes.first(where: { $0.recipeId == recipeID }) ?? summary
    }

    /// Build a `RecipeSummary` from a `RecipeDraft` via JSON round-trip. Derived fields
    /// (isVariant etc.) are left as defaults; reload() will recompute them.
    /// Throws if the hand-built dict no longer matches `RecipeSummary`'s Codable contract.
    private func draftToSummary(_ draft: RecipeDraft, recipeID: String) throws -> RecipeSummary {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // sourceRecipeCount: 0 (derived; reload() recomputes from the full recipe set —
        // never fabricate a non-zero value here or it will disagree with reloaded copies).
        var dict: [String: Any] = [
            "recipeId": recipeID,
            "name": draft.name,
            "mealType": draft.mealType,
            "cuisine": draft.cuisine,
            "instructionsSummary": draft.instructionsSummary,
            "favorite": draft.favorite,
            "archived": false,
            "source": draft.source,
            "sourceLabel": draft.sourceLabel,
            "sourceUrl": draft.sourceUrl,
            "notes": draft.notes,
            "memories": draft.memories,
            "kidFriendly": draft.kidFriendly,
            "iconKey": draft.iconKey,
            "tags": draft.tags,
            "isVariant": draft.baseRecipeId != nil,
            "overrideFields": [String](),
            "variantCount": 0,
            "sourceRecipeCount": 0,
            "updatedAt": Self.iso8601Formatter.string(from: Date()),
        ]
        if let v = draft.servings        { dict["servings"] = v }
        if let v = draft.prepMinutes     { dict["prepMinutes"] = v }
        if let v = draft.cookMinutes     { dict["cookMinutes"] = v }
        if let v = draft.difficultyScore { dict["difficultyScore"] = v }
        if let v = draft.lastUsed        { dict["lastUsed"] = Self.iso8601Formatter.string(from: v) }
        if let v = draft.baseRecipeId    { dict["baseRecipeId"] = v }
        if let v = draft.recipeTemplateId { dict["recipeTemplateId"] = v }
        if let v = draft.imageUrl        { dict["imageUrl"] = v }

        // Children (encode via JSONEncoder since RecipeIngredient/RecipeStep are Codable).
        let ingredientDicts: [[String: Any]] = (try? encoder.encode(draft.ingredients))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let stepDicts: [[String: Any]] = (try? encoder.encode(draft.steps))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        dict["ingredients"] = ingredientDicts
        dict["steps"] = stepDicts

        let data = try JSONSerialization.data(withJSONObject: dict)
        return try decoder.decode(RecipeSummary.self, from: data)
    }

    // MARK: - Date formatting

    /// Shared ISO 8601 formatter — avoids allocating a new instance on every `draftToSummary`
    /// call (mirrors the static formatter pattern used in RecipeRecordMapper).
    private static let iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Diff incoming child records against what's in the store for this recipe.
    /// Save new/changed children; delete removed children individually (not cascading).
    ///
    /// Two invariants are load-bearing and must not be "simplified away":
    ///   1. The `recipe` CKReference filter — substep records carry a `recipe` ref pointing
    ///      to their parent recipe; filtering by it is what scopes the diff to this recipe.
    ///   2. RecipeRecordMapper flattens substeps into `steps` — so `newSteps` already
    ///      contains all step-level records. Removing the filter or changing the mapper's
    ///      flatten behavior will reintroduce orphaned step records in CloudKit.
    private func diffAndApplyChildren(
        newIngredients: [HouseholdRecordValue],
        newSteps: [HouseholdRecordValue],
        deletions: [CKRecord.ID]
    ) throws {
        // Save all incoming children (upsert — changed or new).
        for ing in newIngredients {
            guard upsertRecord(ing) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        for step in newSteps {
            guard upsertRecord(step) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }

        for id in deletions {
            let result = session.engine.delete(id)
            guard result == .allowed else { throw result }
        }
    }

    private func childDeletionIDs(
        recipeID: String,
        newIngredients: [HouseholdRecordValue],
        newSteps: [HouseholdRecordValue]
    ) -> [CKRecord.ID] {
        // Collect existing child record names from the store.
        let store = session.store
        let zoneID = session.zoneID

        let existingIngredientNames = Set(
            store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName)
                .filter { ($0["recipe"] as? CKRecord.Reference)?.recordID.recordName == recipeID }
                .map { $0.recordID.recordName }
        )
        let existingStepNames = Set(
            store.records(ofType: HouseholdRecordType.recipeStep.recordTypeName)
                .filter { ($0["recipe"] as? CKRecord.Reference)?.recordID.recordName == recipeID }
                .map { $0.recordID.recordName }
        )

        let newIngredientNames = Set(newIngredients.map { $0.recordName })
        let newStepNames = Set(newSteps.map { $0.recordName })
        return existingIngredientNames.subtracting(newIngredientNames)
            .union(existingStepNames.subtracting(newStepNames))
            .map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    }

    private func authorizeChildDeletions(_ deletions: [CKRecord.ID]) throws {
        guard !deletions.isEmpty else { return }
        let authorization = session.engine.dataPlaneResult(for: .delete)
        guard authorization == .allowed else { throw authorization }
    }

    // MARK: - Status mutations

    func setFavorite(_ recipeId: String, _ on: Bool) {
        guard let existing = session.store.record(for: CKRecord.ID(recordName: recipeId, zoneID: session.zoneID)) else { return }
        existing["favorite"] = (on ? 1 : 0) as CKRecordValue
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    func archive(_ recipeId: String) {
        guard let existing = session.store.record(for: CKRecord.ID(recordName: recipeId, zoneID: session.zoneID)) else { return }
        existing["archived"] = 1 as CKRecordValue
        existing["archivedAt"] = Date() as CKRecordValue
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    func restore(_ recipeId: String) {
        guard let existing = session.store.record(for: CKRecord.ID(recordName: recipeId, zoneID: session.zoneID)) else { return }
        existing["archived"] = 0 as CKRecordValue
        existing["archivedAt"] = nil
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    @discardableResult
    func delete(_ recipeId: String) -> HouseholdDataPlaneResult {
        let id = CKRecord.ID(recordName: recipeId, zoneID: session.zoneID)
        let cascadeResult = session.engine.deleteCascading(id)
        guard cascadeResult == .allowed else { return cascadeResult }
        // Also delete the image record if present.
        let imageID = CKRecord.ID(
            recordName: RecipeImageCodec.recordName(forRecipe: recipeId),
            zoneID: session.zoneID
        )
        if session.store.record(for: imageID) != nil {
            let imageResult = session.engine.delete(imageID)
            guard imageResult == .allowed else { return imageResult }
        }
        reload()
        Task { [weak self] in await self?.drainSync() }
        return .allowed
    }

    // MARK: - Images

    /// Return the raw bytes of the recipe's header image, or nil if not yet downloaded
    /// or not present.
    func imageBytes(_ recipeId: String) async -> Data? {
        let imgName = RecipeImageCodec.recordName(forRecipe: recipeId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)
        guard let record = session.store.record(for: id) else { return nil }
        guard let image = try? RecipeImageCodec.decode(record) else { return nil }
        return image.imageData
    }

    /// Stage and save a new image for the recipe. The engine will upload the CKAsset
    /// on the next `sendChanges` pass.
    func setImage(_ recipeId: String, _ data: Data, mime: String) {
        let image = RecipeImage(
            recipeID: recipeId,
            mimeType: mime,
            prompt: "",
            generatedAt: Date(),
            imageData: data
        )
        let imgName = RecipeImageCodec.recordName(forRecipe: recipeId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)

        do {
            if let existing = session.store.record(for: id) {
                try RecipeImageCodec.encode(image, into: existing, zoneID: session.zoneID)
                session.engine.save(existing)
            } else {
                let record = try RecipeImageCodec.makeRecord(image, zoneID: session.zoneID)
                session.engine.save(record)
            }
            reload()
            Task { [weak self] in await self?.drainSync() }
        } catch {
            // Staging the asset file failed (disk full, etc.); leave the store untouched.
        }
    }

    /// Stage images for multiple recipes WITHOUT reloading or draining after each one.
    /// After the loop, the caller should call `reload()` once and then `drainSync()`
    /// (or spawn a task for it). Used by `backfillRecipeImages` to avoid O(N²) reloads
    /// and N concurrent drain tasks (AI-4 review fix F3).
    func stageImage(_ recipeId: String, _ data: Data, mime: String) {
        let image = RecipeImage(
            recipeID: recipeId,
            mimeType: mime,
            prompt: "",
            generatedAt: Date(),
            imageData: data
        )
        let imgName = RecipeImageCodec.recordName(forRecipe: recipeId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)

        do {
            if let existing = session.store.record(for: id) {
                try RecipeImageCodec.encode(image, into: existing, zoneID: session.zoneID)
                session.engine.save(existing)
            } else {
                let record = try RecipeImageCodec.makeRecord(image, zoneID: session.zoneID)
                session.engine.save(record)
            }
            // No reload() or drainSync() — caller batches those.
        } catch {
            // Staging the asset file failed (disk full, etc.); leave the store untouched.
        }
    }

    /// Delete the recipe's image record.
    @discardableResult
    func removeImage(_ recipeId: String) -> HouseholdDataPlaneResult {
        let imgName = RecipeImageCodec.recordName(forRecipe: recipeId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)
        guard session.store.record(for: id) != nil else { return .allowed }
        let result = session.engine.delete(id)
        guard result == .allowed else { return result }
        reload()
        Task { [weak self] in await self?.drainSync() }
        return .allowed
    }

    // MARK: - Memories (SP-D 990.4.1)
    //
    // RecipeMemory is a plain-scalar manifest type (body/createdAt) — no dedicated codec
    // struct, decoded generically via HouseholdRecordCodec like recipe/recipeIngredient
    // (typed domain structs only exist for asset-carrying types, per HouseholdRecordValue's
    // own doc comment). RecipeMemoryImage IS a dedicated CKAsset codec, mirroring
    // RecipeImageCodec exactly. UI wiring is 990.4.2's job; this section is CRUD only.

    /// All memory entries for a recipe, oldest→newest (client-side sort — the manifest field
    /// is SORTABLE but the sync engine fetches the zone whole; mirrors how `reload()` groups
    /// ingredient/step children by their `recipe` ref).
    func memories(forRecipe recipeId: String) -> [RecipeMemoryEntry] {
        let store = session.store
        let imageNames = Set(
            store.records(ofType: RecipeMemoryImageCodec.recordType).map { $0.recordID.recordName }
        )
        let entries: [RecipeMemoryEntry] = store
            .records(ofType: HouseholdRecordType.recipeMemory.recordTypeName)
            .compactMap { record in
                let value = HouseholdRecordCodec.decode(record, as: .recipeMemory)
                guard value.refs["recipe"] == recipeId else { return nil }
                return RecipeMemoryEntry(
                    id: value.recordName,
                    body: scalarString(value, "body") ?? "",
                    createdAt: scalarDate(value, "createdAt") ?? Date(timeIntervalSince1970: 0),
                    hasPhoto: imageNames.contains(RecipeMemoryImageCodec.recordName(forMemory: value.recordName))
                )
            }
        return entries.sorted { $0.createdAt < $1.createdAt }
    }

    /// Create a new memory log entry for a recipe. Returns the new memory's id.
    @discardableResult
    func addMemory(_ recipeId: String, body: String, createdAt: Date = Date()) -> String {
        let memoryId = UUID().uuidString
        let value = HouseholdRecordValue(
            type: .recipeMemory, recordName: memoryId,
            scalars: ["body": .string(body), "createdAt": .date(createdAt)],
            refs: ["recipe": recipeId]
        )
        upsertRecord(value)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return memoryId
    }

    /// Delete a memory entry. `deleteCascading` sweeps its RecipeMemoryImage via the local
    /// `.deleteSelf` subtree scan; the explicit delete below is belt-and-suspenders,
    /// mirroring `delete(_:)`'s equivalent extra step for RecipeImage.
    @discardableResult
    func deleteMemory(_ memoryId: String) -> HouseholdDataPlaneResult {
        let id = CKRecord.ID(recordName: memoryId, zoneID: session.zoneID)
        let cascadeResult = session.engine.deleteCascading(id)
        guard cascadeResult == .allowed else { return cascadeResult }
        let imageID = CKRecord.ID(
            recordName: RecipeMemoryImageCodec.recordName(forMemory: memoryId),
            zoneID: session.zoneID
        )
        if session.store.record(for: imageID) != nil {
            let imageResult = session.engine.delete(imageID)
            guard imageResult == .allowed else { return imageResult }
        }
        reload()
        Task { [weak self] in await self?.drainSync() }
        return .allowed
    }

    // MARK: - Memory photos

    /// Return the raw bytes of a memory's photo, or nil if not yet downloaded or not present.
    func memoryPhotoBytes(_ memoryId: String) async -> Data? {
        let imgName = RecipeMemoryImageCodec.recordName(forMemory: memoryId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)
        guard let record = session.store.record(for: id) else { return nil }
        guard let image = try? RecipeMemoryImageCodec.decode(record) else { return nil }
        return image.imageData
    }

    /// Stage and save a photo for a memory. The engine uploads the CKAsset on the next
    /// `sendChanges` pass.
    func setMemoryPhoto(_ memoryId: String, _ data: Data, mime: String) {
        let image = RecipeMemoryImage(memoryID: memoryId, mimeType: mime, createdAt: Date(), imageData: data)
        let imgName = RecipeMemoryImageCodec.recordName(forMemory: memoryId)
        let id = CKRecord.ID(recordName: imgName, zoneID: session.zoneID)

        do {
            if let existing = session.store.record(for: id) {
                try RecipeMemoryImageCodec.encode(image, into: existing, zoneID: session.zoneID)
                session.engine.save(existing)
            } else {
                let record = try RecipeMemoryImageCodec.makeRecord(image, zoneID: session.zoneID)
                session.engine.save(record)
            }
            reload()
            Task { [weak self] in await self?.drainSync() }
        } catch {
            // Staging the asset file failed (disk full, etc.); leave the store untouched.
        }
    }

    // MARK: - Memory scalar accessors

    private func scalarString(_ value: HouseholdRecordValue, _ key: String) -> String? {
        if case let .string(v)? = value.scalars[key] { return v }
        return nil
    }

    private func scalarDate(_ value: HouseholdRecordValue, _ key: String) -> Date? {
        if case let .date(v)? = value.scalars[key] { return v }
        return nil
    }
}
#endif
