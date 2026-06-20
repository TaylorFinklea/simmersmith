import Foundation
import HouseholdRecords

// SP-C Task 1 — RecipeSummary ⇄ HouseholdRecordValue mapper (both directions).
//
// Moved from the app target to SimmerSmithKit so the mapper can be tested headlessly
// via `swift test` without building the full app target.
//
// Field classification (mirrors spec §5):
//   A. Direct scalar ↔ .recipe record scalar field (1:1)
//   B. Serialized scalar — tags: [String] ↔ tags: String (JSON array, see encodeTags)
//   C. References — baseRecipe (.setNullInZone), recipeTemplateID (.crossDBString)
//      overridePayloadJSON is a direct scalar (already a String in both domain and record)
//   D. Child records — .recipeIngredient, .recipeStep (with parentStep for substeps)
//   E. Image — no scalar analog; represented by hasImage parameter on reverse map
//   F. Derived / computed — NOT stored; returned as nil/0/empty on reverse map:
//      daysSinceLastUsed, familyDaysSinceLastUsed, familyLastUsed, isVariant,
//      variantCount, sourceRecipeCount, overrideFields, nutritionSummary
//
// tags format: JSON array of strings, e.g. `["quick","veg"]`. This matches the
// Postgres `recipes.tags` Text column serialization in `app/services/recipes.py`:
//   `serialize_tag_list(tags)` → `json.dumps(normalize_tag_list(tags))`
// Migrated recipes therefore carry the same JSON-array format in their CloudKit record.
// An empty list encodes as "[]" and decodes back to [].

public enum RecipeRecordMapper {

    // MARK: - Shared formatters

    // ISO8601DateFormatter is not Sendable, but is safe to use from multiple threads
    // when only calling string(from:) (read-only after initialization).
    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Domain → Records

    /// Map a `RecipeSummary` to its primary record plus its child ingredient and step records.
    /// Mirrors `migrateHouseholdRecord` in HouseholdRecordMigration.swift: only set non-nil/non-empty
    /// scalars; omit absent values (CloudKit's all-optional columns stay absent). Refs are only set
    /// when non-nil.
    public static func records(from recipe: RecipeSummary)
        -> (recipe: HouseholdRecordValue, ingredients: [HouseholdRecordValue], steps: [HouseholdRecordValue])
    {
        let recipeRecord = buildRecipeRecord(recipe)
        let ingredientRecords = recipe.ingredients.enumerated().map { idx, ing in
            buildIngredientRecord(ing, recipeId: recipe.recipeId, fallbackIndex: idx)
        }
        // Flatten: top-level steps first, then substeps. Each substep carries a parentStep ref.
        let stepRecords = buildStepRecords(recipe.steps, recipeId: recipe.recipeId)

        return (recipeRecord, ingredientRecords, stepRecords)
    }

    // MARK: - Records → Domain

    /// Reconstruct a `RecipeSummary` from its CloudKit record set.
    /// Category-F (derived) fields are NOT echoed from the record — they are returned as nil/0/empty.
    /// `hasImage` replaces `imageUrl`: pass true when a RecipeImage record exists for this recipe.
    public static func recipe(
        from rec: HouseholdRecordValue,
        ingredients: [HouseholdRecordValue],
        steps: [HouseholdRecordValue],
        hasImage: Bool
    ) -> RecipeSummary {
        let s = rec.scalars
        let r = rec.refs

        // Build top-level steps and attach substeps.
        let domainSteps = buildDomainSteps(steps)

        // RecipeSummary has no public memberwise init; construct via JSON round-trip.
        var dict: [String: Any] = [
            "recipeId": rec.recordName,
            "name": string(s, "name") ?? "",
            "mealType": string(s, "mealType") ?? "",
            "cuisine": string(s, "cuisine") ?? "",
            "instructionsSummary": string(s, "instructionsSummary") ?? "",
            "favorite": bool(s, "favorite") ?? false,
            "archived": bool(s, "archived") ?? false,
            "source": string(s, "source") ?? "manual",
            "sourceLabel": string(s, "sourceLabel") ?? "",
            "sourceUrl": string(s, "sourceURL") ?? "",   // manifest field is sourceURL; domain struct key is sourceUrl
            "notes": string(s, "notes") ?? "",
            "memories": string(s, "memories") ?? "",
            "kidFriendly": bool(s, "kidFriendly") ?? false,
            "iconKey": string(s, "iconKey") ?? "",
            // Derived fields (§5-F) — NOT echoed; computed client-side or deferred.
            "isVariant": false,
            "overrideFields": [String](),
            "variantCount": 0,
            "sourceRecipeCount": 0,  // derived; repository recomputes — never fabricate
            // updatedAt is required (non-optional) — use stored value or now.
            "updatedAt": iso8601(date(s, "updatedAt") ?? Date()),
        ]

        // Optional scalars — only include when present in the record.
        if let v = double(s, "servings")        { dict["servings"] = v }
        if let v = int(s, "prepMinutes")        { dict["prepMinutes"] = v }
        if let v = int(s, "cookMinutes")        { dict["cookMinutes"] = v }
        if let v = int(s, "difficultyScore")    { dict["difficultyScore"] = v }
        if let v = date(s, "archivedAt")        { dict["archivedAt"] = iso8601(v) }
        if let v = date(s, "lastUsed")          { dict["lastUsed"] = iso8601(v) }
        if let v = string(s, "overridePayloadJSON") { dict["overridePayloadJSON"] = v }

        // Tags (§5-B): decode from JSON array string.
        if let tagsStr = string(s, "tags") {
            dict["tags"] = decodeTags(tagsStr)
        } else {
            dict["tags"] = [String]()
        }

        // References (§5-C).
        if let base = r["baseRecipe"] { dict["baseRecipeId"] = base }
        if let tmpl = r["recipeTemplateID"] { dict["recipeTemplateId"] = tmpl }

        // Children (§5-D).
        dict["ingredients"] = ingredients.map { ingredientDict($0) }
        dict["steps"] = domainSteps.map { stepDict($0) }

        // Image (§5-E): imageUrl is nil when hasImage==false; the view fetches bytes via RecipeImageCodec.
        if hasImage {
            dict["imageUrl"] = "ckasset://\(rec.recordName)"
        }

        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(RecipeSummary.self, from: jsonData)
    }

    // MARK: - Tag serialization (§5-B)

    /// Encode a tag array to the JSON-array string format used in the Postgres `recipes.tags` column
    /// and in CloudKit records for migrated recipes.
    /// Format: `["quick","veg"]`. Empty list → `"[]"`.
    /// This matches `serialize_tag_list` in `app/services/recipes.py`.
    public static func encodeTags(_ tags: [String]) -> String {
        let data = try! JSONEncoder().encode(tags)
        return String(data: data, encoding: .utf8)!
    }

    /// Decode a JSON-array tag string back to `[String]`.
    /// Returns `[]` on empty string or malformed input.
    public static func decodeTags(_ s: String) -> [String] {
        guard !s.isEmpty,
              let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }

    // MARK: - Private helpers: domain → record

    private static func buildRecipeRecord(_ recipe: RecipeSummary) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        // Category-A direct scalars.
        set(&scalars, "name", .string(recipe.name))
        setIfNonEmpty(&scalars, "mealType", recipe.mealType)
        setIfNonEmpty(&scalars, "cuisine", recipe.cuisine)
        if let v = recipe.servings       { scalars["servings"] = .double(v) }
        if let v = recipe.prepMinutes    { scalars["prepMinutes"] = .int(v) }
        if let v = recipe.cookMinutes    { scalars["cookMinutes"] = .int(v) }
        setIfNonEmpty(&scalars, "instructionsSummary", recipe.instructionsSummary)
        scalars["favorite"] = .bool(recipe.favorite)
        scalars["archived"] = .bool(recipe.archived)
        setIfNonEmpty(&scalars, "source", recipe.source)
        setIfNonEmpty(&scalars, "sourceLabel", recipe.sourceLabel)
        setIfNonEmpty(&scalars, "sourceURL", recipe.sourceUrl)  // manifest field: sourceURL
        setIfNonEmpty(&scalars, "notes", recipe.notes)
        setIfNonEmpty(&scalars, "memories", recipe.memories)
        if let v = recipe.lastUsed       { scalars["lastUsed"] = .date(v) }
        scalars["kidFriendly"] = .bool(recipe.kidFriendly)
        if let v = recipe.difficultyScore { scalars["difficultyScore"] = .int(v) }
        setIfNonEmpty(&scalars, "iconKey", recipe.iconKey)
        if let v = recipe.archivedAt     { scalars["archivedAt"] = .date(v) }
        scalars["updatedAt"] = .date(Date())

        // Category-B serialized.
        scalars["tags"] = .string(encodeTags(recipe.tags))

        // Category-C overridePayloadJSON (direct scalar even though it's a JSON string).
        // Not stored on RecipeSummary directly (it's a variant override blob); omit when absent.

        var refs: [String: String] = [:]
        // Category-C references.
        if let base = recipe.baseRecipeId       { refs["baseRecipe"] = base }
        if let tmpl = recipe.recipeTemplateId   { refs["recipeTemplateID"] = tmpl }

        return HouseholdRecordValue(type: .recipe, recordName: recipe.recipeId, scalars: scalars, refs: refs)
    }

    private static func buildIngredientRecord(
        _ ing: RecipeIngredient,
        recipeId: String,
        fallbackIndex: Int
    ) -> HouseholdRecordValue {
        let recordName = ing.ingredientId ?? "\(recipeId)_ing_\(fallbackIndex)"
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "ingredientName", .string(ing.ingredientName))
        if let v = ing.normalizedName, !v.isEmpty { scalars["normalizedName"] = .string(v) }
        if let v = ing.quantity                   { scalars["quantity"] = .double(v) }
        setIfNonEmpty(&scalars, "unit", ing.unit)
        setIfNonEmpty(&scalars, "prep", ing.prep)
        setIfNonEmpty(&scalars, "category", ing.category)
        setIfNonEmpty(&scalars, "notes", ing.notes)
        setIfNonEmpty(&scalars, "resolutionStatus", ing.resolutionStatus)
        scalars["updatedAt"] = .date(Date())

        var refs: [String: String] = [:]
        refs["recipe"] = recipeId   // cascadeParent
        if let v = ing.baseIngredientId      { refs["baseIngredientID"] = v }
        if let v = ing.ingredientVariationId { refs["ingredientVariationID"] = v }

        return HouseholdRecordValue(type: .recipeIngredient, recordName: recordName, scalars: scalars, refs: refs)
    }

    /// Flatten top-level steps + their substeps into a flat list of records.
    /// Each substep carries a `parentStep` cascadeParent ref to its parent step's recordName.
    private static func buildStepRecords(_ steps: [RecipeStep], recipeId: String) -> [HouseholdRecordValue] {
        var records: [HouseholdRecordValue] = []
        for (idx, step) in steps.enumerated() {
            let stepName = step.stepId ?? "\(recipeId)_step_\(idx)"
            records.append(buildStepRecord(step, recordName: stepName, recipeId: recipeId, parentStepId: nil))
            for (subIdx, substep) in step.substeps.enumerated() {
                let subName = substep.stepId ?? "\(recipeId)_step_\(idx)_sub_\(subIdx)"
                records.append(buildStepRecord(substep, recordName: subName, recipeId: recipeId, parentStepId: stepName))
            }
        }
        return records
    }

    private static func buildStepRecord(
        _ step: RecipeStep,
        recordName: String,
        recipeId: String,
        parentStepId: String?
    ) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]
        scalars["sortOrder"] = .int(step.sortOrder)
        set(&scalars, "instruction", .string(step.instruction))
        scalars["updatedAt"] = .date(Date())

        var refs: [String: String] = [:]
        refs["recipe"] = recipeId
        if let p = parentStepId { refs["parentStep"] = p }

        return HouseholdRecordValue(type: .recipeStep, recordName: recordName, scalars: scalars, refs: refs)
    }

    // MARK: - Private helpers: record → domain

    private static func buildDomainSteps(_ stepRecords: [HouseholdRecordValue]) -> [RecipeStep] {
        // Separate top-level steps (no parentStep ref) from substeps.
        var topLevel: [HouseholdRecordValue] = []
        var substepsByParent: [String: [HouseholdRecordValue]] = [:]

        for rec in stepRecords {
            if let parent = rec.refs["parentStep"] {
                substepsByParent[parent, default: []].append(rec)
            } else {
                topLevel.append(rec)
            }
        }

        // Sort by sortOrder.
        let sorted = topLevel.sorted { sortOrder($0) < sortOrder($1) }
        return sorted.map { rec in
            let subs = (substepsByParent[rec.recordName] ?? [])
                .sorted { sortOrder($0) < sortOrder($1) }
                .map { domainStep($0, substeps: []) }
            return domainStep(rec, substeps: subs)
        }
    }

    private static func domainStep(_ rec: HouseholdRecordValue, substeps: [RecipeStep]) -> RecipeStep {
        RecipeStep(
            stepId: rec.recordName,
            sortOrder: sortOrder(rec),
            instruction: string(rec.scalars, "instruction") ?? "",
            substeps: substeps
        )
    }

    private static func sortOrder(_ rec: HouseholdRecordValue) -> Int {
        if case let .int(v) = rec.scalars["sortOrder"] { return v }
        return 0
    }

    /// Build a dictionary representation of a `RecipeIngredient` for JSON round-trip.
    private static func ingredientDict(_ rec: HouseholdRecordValue) -> [String: Any] {
        var d: [String: Any] = [
            "ingredientName": string(rec.scalars, "ingredientName") ?? "",
            "resolutionStatus": string(rec.scalars, "resolutionStatus") ?? "unresolved",
            "unit": string(rec.scalars, "unit") ?? "",
            "prep": string(rec.scalars, "prep") ?? "",
            "category": string(rec.scalars, "category") ?? "",
            "notes": string(rec.scalars, "notes") ?? "",
        ]
        d["ingredientId"] = rec.recordName
        if let v = string(rec.scalars, "normalizedName") { d["normalizedName"] = v }
        if let v = double(rec.scalars, "quantity")       { d["quantity"] = v }
        if let v = rec.refs["baseIngredientID"]          { d["baseIngredientId"] = v }
        if let v = rec.refs["ingredientVariationID"]     { d["ingredientVariationId"] = v }
        return d
    }

    /// Build a dictionary representation of a `RecipeStep` for JSON round-trip (substeps handled separately).
    private static func stepDict(_ step: RecipeStep) -> [String: Any] {
        var d: [String: Any] = [
            "sortOrder": step.sortOrder,
            "instruction": step.instruction,
        ]
        if let id = step.stepId { d["stepId"] = id }
        if !step.substeps.isEmpty {
            d["substeps"] = step.substeps.map { stepDict($0) }
        }
        return d
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
