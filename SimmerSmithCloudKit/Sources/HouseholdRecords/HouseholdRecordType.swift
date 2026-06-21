import Foundation

// SP-A Phase 2b — the household zone's typed plain-CRUD record manifest.
//
// This is the IRREVERSIBLE part: recordName policy, field names + CloudKit types, and the
// CASCADE/SET-NULL reference graph for every household-scoped plain-CRUD record. It is the
// single source of truth that drives BOTH the CKRecord codec (HouseholdRecordCodec) and the
// CKDSL schema (`ckdsl()` → appended to phase0-schema.ckdb). Pure Swift → unit-tested
// headlessly; concurrency-safe value types only.
//
// 2b records are INERT last-writer-wins pass-through on the Phase-2a HouseholdSyncEngine —
// no merge logic. The grocery/event field-merge (Phase 4/5) swaps in at the engine's
// documented LWW seams; it does NOT touch this manifest.
//
// Conventions (mirror the deployed phase0-schema.ckdb): camelCase field names, `ID` suffix
// for string foreign keys, CKReference fields named by the parent role. Bool → INT64 (0/1),
// matching the deployed `active INT64` convention. household_id / user_id columns are
// DROPPED — the zone identity (and its owner) replaces them; no record carries household_id.

/// CloudKit scalar field types. `bool` is stored as INT64 0/1.
public enum CKFieldType: Equatable {
    case string, int, double, date, bool
}

public struct FieldSpec: Equatable {
    public let name: String
    public let type: CKFieldType
    public let queryable: Bool
    public let sortable: Bool
    public init(_ name: String, _ type: CKFieldType, queryable: Bool = false, sortable: Bool = false) {
        self.name = name; self.type = type; self.queryable = queryable; self.sortable = sortable
    }
}

/// How a foreign key encodes onto CloudKit.
public enum RefKind: Equatable {
    /// In-zone CKReference with action `.deleteSelf` — deleting the target cascades to this
    /// record. The issuing engine also sweeps children locally (CloudKit's `.deleteSelf`
    /// only fires on the deleting device).
    case cascadeParent
    /// In-zone CKReference with action `.none` — a dangling target nulls locally, never crashes.
    case setNullInZone
    /// A plain STRING recordName key, NOT a CKReference. Used when the target may live in a
    /// DIFFERENT database (PUBLIC catalog) or a not-yet-defined type (Phase-4 Week) — a
    /// CKReference there is illegal / would fail validate-schema. SET-NULL by nulling the string.
    case crossDBString
}

public struct RefSpec: Equatable {
    public let name: String
    public let kind: RefKind
    /// CloudKit record type the reference points at (for in-zone refs); informational for crossDBString.
    public let target: String
    public init(_ name: String, _ kind: RefKind, target: String) {
        self.name = name; self.kind = kind; self.target = target
    }
}

public enum RecordNamePolicy: Equatable {
    /// recordName == the legacy String primary key, verbatim.
    case pk
    /// recordName is a deterministic key built from RecordNames (collisions collapse).
    case det
}

/// Every household-scoped plain-CRUD record type landed in Phase 2b.
///
/// HouseholdProfile shipped in Phase 0. Grocery/Event-grocery types carry field-merge logic and
/// keep dedicated codecs (GroceryCodec/EventGroceryCodec). Week / WeekMeal / WeekChangeBatch /
/// WeekChangeEvent landed in Phase 4-remainder as plain LWW manifest records (their cross-record
/// repair — slot-swap, week-collapse, sort-order, audit-prune — runs as an adapter over the
/// engine, not in the codec). FeedbackEntry remains deferred (independent; no repair machinery).
public enum HouseholdRecordType: String, CaseIterable, Equatable {
    case householdSetting
    case householdTermAlias
    case recipe
    case recipeIngredient
    case recipeStep
    case guest
    case event
    case eventAttendee
    case eventMeal
    case eventMealIngredient
    case baseIngredient
    case ingredientVariation
    case week
    case weekMeal
    case weekMealSide
    case weekChangeBatch
    case weekChangeEvent
    case managedListItem
    case pantryItem

    /// The CloudKit record type name.
    public var recordTypeName: String {
        switch self {
        case .householdSetting: return "HouseholdSetting"
        case .householdTermAlias: return "HouseholdTermAlias"
        case .recipe: return "Recipe"
        case .recipeIngredient: return "RecipeIngredient"
        case .recipeStep: return "RecipeStep"
        case .guest: return "Guest"
        case .event: return "Event"
        case .eventAttendee: return "EventAttendee"
        case .eventMeal: return "EventMeal"
        case .eventMealIngredient: return "EventMealIngredient"
        case .baseIngredient: return "BaseIngredient"
        case .ingredientVariation: return "IngredientVariation"
        case .week: return "Week"
        case .weekMeal: return "WeekMeal"
        case .weekMealSide: return "WeekMealSide"
        case .weekChangeBatch: return "WeekChangeBatch"
        case .weekChangeEvent: return "WeekChangeEvent"
        case .managedListItem: return "ManagedListItem"
        case .pantryItem: return "PantryItem"
        }
    }

    public var namePolicy: RecordNamePolicy {
        switch self {
        // Composite/keyed PKs in Postgres → deterministic recordNames (no surrogate id to pass through).
        case .householdSetting, .householdTermAlias, .eventAttendee, .managedListItem: return .det
        default: return .pk   // .pantryItem uses its legacy UUID id as recordName
        }
    }

    /// Scalar (non-reference) fields. QUERYABLE/SORTABLE per phase0-schema.md §B only.
    public var fields: [FieldSpec] {
        switch self {
        case .householdSetting:
            return [F("key", .string, queryable: true), F("value", .string), F("updatedAt", .date)]
        case .householdTermAlias:
            return [F("term", .string, queryable: true), F("expansion", .string), F("notes", .string),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .recipe:
            return [F("name", .string), F("mealType", .string), F("cuisine", .string, queryable: true),
                    F("servings", .double), F("prepMinutes", .int), F("cookMinutes", .int),
                    F("tags", .string), F("instructionsSummary", .string), F("favorite", .bool),
                    F("archived", .bool), F("source", .string), F("sourceLabel", .string),
                    F("sourceURL", .string), F("notes", .string), F("memories", .string),
                    F("overridePayloadJSON", .string), F("iconKey", .string), F("lastUsed", .date),
                    F("difficultyScore", .int), F("kidFriendly", .bool), F("archivedAt", .date),
                    F("createdAt", .date, sortable: true), F("updatedAt", .date)]
        case .recipeIngredient:
            return [F("ingredientName", .string), F("normalizedName", .string), F("quantity", .double),
                    F("unit", .string), F("prep", .string), F("category", .string), F("notes", .string),
                    F("resolutionStatus", .string), F("createdAt", .date), F("updatedAt", .date)]
        case .recipeStep:
            return [F("sortOrder", .int), F("instruction", .string), F("createdAt", .date), F("updatedAt", .date)]
        case .guest:
            return [F("name", .string), F("relationshipLabel", .string), F("dietaryNotes", .string),
                    F("allergies", .string), F("ageGroup", .string), F("active", .bool),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .event:
            return [F("name", .string), F("eventDate", .date, sortable: true), F("occasion", .string),
                    F("attendeeCount", .int), F("notes", .string), F("status", .string),
                    F("autoMergeGrocery", .bool), F("manuallyMerged", .bool),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .eventAttendee:
            return [F("plusOnes", .int), F("createdAt", .date)]
        case .eventMeal:
            return [F("role", .string), F("recipeName", .string), F("servings", .double),
                    F("scaleMultiplier", .double), F("notes", .string), F("sortOrder", .int),
                    F("aiGenerated", .bool), F("approved", .bool), F("constraintCoverage", .string),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .eventMealIngredient:
            return [F("ingredientName", .string), F("normalizedName", .string), F("quantity", .double),
                    F("unit", .string), F("prep", .string), F("category", .string), F("notes", .string),
                    F("resolutionStatus", .string), F("createdAt", .date), F("updatedAt", .date)]
        case .baseIngredient:
            return [F("name", .string), F("normalizedName", .string, queryable: true),
                    F("submissionStatus", .string), F("category", .string), F("defaultUnit", .string),
                    F("notes", .string), F("sourceName", .string), F("sourceRecordID", .string),
                    F("sourceURL", .string), F("sourcePayloadJSON", .string), F("overridePayloadJSON", .string),
                    F("provisional", .bool), F("active", .bool), F("archivedAt", .date),
                    F("nutritionReferenceAmount", .double), F("nutritionReferenceUnit", .string),
                    F("calories", .double), F("proteinG", .double), F("carbsG", .double),
                    F("fatG", .double), F("fiberG", .double), F("createdAt", .date), F("updatedAt", .date)]
        case .ingredientVariation:
            return [F("name", .string), F("normalizedName", .string, queryable: true), F("brand", .string),
                    F("upc", .string), F("packageSizeAmount", .double), F("packageSizeUnit", .string),
                    F("countPerPackage", .double), F("productURL", .string), F("retailerHint", .string),
                    F("notes", .string), F("sourceName", .string), F("sourceRecordID", .string),
                    F("sourceURL", .string), F("sourcePayloadJSON", .string), F("overridePayloadJSON", .string),
                    F("active", .bool), F("archivedAt", .date), F("nutritionReferenceAmount", .double),
                    F("nutritionReferenceUnit", .string), F("calories", .double), F("proteinG", .double),
                    F("carbsG", .double), F("fatG", .double), F("fiberG", .double),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .week:
            return [F("weekStart", .date, queryable: true, sortable: true), F("weekEnd", .date),
                    F("status", .string), F("notes", .string), F("readyForAIAt", .date),
                    F("approvedAt", .date), F("pricedAt", .date),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .weekMeal:
            return [F("dayName", .string), F("mealDate", .date), F("slot", .string),
                    F("recipeName", .string), F("servings", .double), F("scaleMultiplier", .double),
                    F("source", .string), F("approved", .bool), F("notes", .string),
                    F("aiGenerated", .bool), F("sortOrder", .int),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .weekMealSide:
            return [F("recipeName", .string), F("name", .string), F("notes", .string),
                    F("sortOrder", .int), F("createdAt", .date), F("updatedAt", .date)]
        case .weekChangeBatch:
            return [F("actorType", .string), F("actorLabel", .string), F("summary", .string),
                    F("createdAt", .date)]
        case .weekChangeEvent:
            return [F("entityType", .string), F("entityID", .string), F("fieldName", .string),
                    F("beforeValue", .string), F("afterValue", .string), F("createdAt", .date)]
        case .managedListItem:
            // Backend: managed_list_items (kind, name, normalized_name, created_at, updated_at).
            // No sort_order or built_in on the actual model. kind is queryable for list-by-kind
            // queries. normalizedName stored for dedup awareness on the client.
            return [F("kind", .string, queryable: true), F("name", .string),
                    F("normalizedName", .string),
                    F("createdAt", .date), F("updatedAt", .date)]
        case .pantryItem:
            // SP-C Task 1 (spec §2): household-zone pantry staple. recordName policy: .pk (legacy UUID id).
            // categories: JSON-array string (same serialization as Recipe.tags).
            // No refs — PantryItem is a top-level aggregate root.
            return [F("stapleName", .string), F("normalizedName", .string),
                    F("notes", .string), F("isActive", .bool),
                    F("typicalQuantity", .double), F("typicalUnit", .string),
                    F("recurringQuantity", .double), F("recurringUnit", .string),
                    F("recurringCadence", .string),
                    F("category", .string), F("categories", .string),
                    F("lastAppliedAt", .date), F("frozenAt", .date),
                    F("createdAt", .date), F("updatedAt", .date)]
        }
    }

    /// Reference graph. THE load-bearing irreversible classification (verified vs the
    /// production SQLAlchemy ondelete rules + spec §6.3 + phase0-schema.md §A/§C).
    public var refs: [RefSpec] {
        switch self {
        case .householdSetting, .householdTermAlias:
            return []
        case .recipe:
            // Top-level. base_recipe_id is a SET-NULL self-ref (NOT cascade — swapping this
            // with RecipeStep.parent_step_id would delete variants when a base is removed).
            // recipe_template_id is cross-DB PUBLIC → String.
            return [R("baseRecipe", .setNullInZone, target: "Recipe"),
                    R("recipeTemplateID", .crossDBString, target: "RecipeTemplate")]
        case .recipeIngredient:
            return [R("recipe", .cascadeParent, target: "Recipe"),
                    R("baseIngredientID", .crossDBString, target: "BaseIngredient"),
                    R("ingredientVariationID", .crossDBString, target: "IngredientVariation")]
        case .recipeStep:
            // Both edges are CASCADE in Postgres (recipe_id + parent_step_id self-ref).
            return [R("recipe", .cascadeParent, target: "Recipe"),
                    R("parentStep", .cascadeParent, target: "RecipeStep")]
        case .guest:
            return []
        case .event:
            // linked_week_id → Week is a Phase-4 record; encode as a String key (SET-NULL by
            // nulling) so it survives until Week's type exists. Stays a String key thereafter.
            return [R("linkedWeekID", .crossDBString, target: "Week")]
        case .eventAttendee:
            // event is THE cascade parent; guest is SET-NULL per spec §6.3 (overrides the
            // Postgres guest_id CASCADE — CloudKit's one-issuing-device cascade + the spec's
            // soft-edge intent). DET key order is fixed <eventID>_<guestID>.
            return [R("event", .cascadeParent, target: "Event"),
                    R("guest", .setNullInZone, target: "Guest")]
        case .eventMeal:
            return [R("event", .cascadeParent, target: "Event"),
                    R("recipe", .setNullInZone, target: "Recipe"),
                    R("assignedGuest", .setNullInZone, target: "Guest")]
        case .eventMealIngredient:
            return [R("eventMeal", .cascadeParent, target: "EventMeal"),
                    R("baseIngredientID", .crossDBString, target: "BaseIngredient"),
                    R("ingredientVariationID", .crossDBString, target: "IngredientVariation")]
        case .baseIngredient:
            // merged_into_id may point at a now-PUBLIC approved row (cross-DB) → String, never
            // a CKReference. The depth-capped, cycle-guarded walk is client-side over strings.
            return [R("mergedIntoID", .crossDBString, target: "BaseIngredient")]
        case .ingredientVariation:
            // base_ingredient_id is ondelete=CASCADE (catalog.py:137) → the cascade parent.
            return [R("baseIngredient", .cascadeParent, target: "BaseIngredient"),
                    R("mergedIntoID", .crossDBString, target: "IngredientVariation")]
        case .week:
            // Aggregate root of the household zone (spec §6.3 "Week→subtree" CASCADE). No outbound refs.
            return []
        case .weekMeal:
            // week_id CASCADE (week.py:96); recipe_id SET NULL (week.py:100, spec §6.3 soft edge).
            return [R("week", .cascadeParent, target: "Week"),
                    R("recipe", .setNullInZone, target: "Recipe")]
        case .weekMealSide:
            // week_meal_id CASCADE (spec §2 "cascadeParent→WeekMeal"); recipe_id SET NULL (soft edge — side
            // can outlive a deleted recipe, just loses the link).
            return [R("weekMeal", .cascadeParent, target: "WeekMeal"),
                    R("recipe", .setNullInZone, target: "Recipe")]
        case .weekChangeBatch:
            // week_id CASCADE (week.py:283) — audit batches die with their week.
            return [R("week", .cascadeParent, target: "Week")]
        case .weekChangeEvent:
            // batch_id CASCADE (week.py:301) — events die with their batch (so the audit-prune,
            // which deletes batches, sweeps their events via the engine's local cascade).
            return [R("batch", .cascadeParent, target: "WeekChangeBatch")]
        case .managedListItem:
            // No foreign keys — a top-level household-owned reference-data record.
            return []
        case .pantryItem:
            // No foreign keys — a top-level household-owned staple record (spec §2).
            return []
        }
    }

    private func F(_ n: String, _ t: CKFieldType, queryable: Bool = false, sortable: Bool = false) -> FieldSpec {
        FieldSpec(n, t, queryable: queryable, sortable: sortable)
    }
    private func R(_ n: String, _ k: RefKind, target: String) -> RefSpec { RefSpec(n, k, target: target) }
}
