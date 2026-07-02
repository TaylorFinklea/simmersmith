#if canImport(CloudKit)
import Foundation
import SimmerSmithKit
import AIProviderKit

// SP-C AI-5 (T3) — ToolRegistry: the curated v1 assistant toolset that the on-device
// AssistantEngine (T2) drives. Each tool is a `ToolSpec` (name + description + JSON
// input_schema, porting the server's `app/mcp/*` arg shapes) plus an `execute` that runs
// `@MainActor` against the CloudKit repos through AppState's façades — so WRITE tools go
// through the SAME paths the UI does (AppState.saveWeekMeals → grocery regenerates,
// AppState.saveRecipe → RecipeRepository + mirror, the AI-1 week-gen, the AI-2 drafts) and
// stay CloudKit-correct.
//
// The engine consumes two things from here:
//   • `specs: [ToolSpec]`           — handed to `BYOKeyProvider.chatWithTools` each iteration.
//   • `runner: AssistantToolRunner` — `@Sendable (ToolCall) async -> ToolRunResult`; the
//     engine calls it per requested tool. The closure dispatches by `call.name` into the
//     matching `@MainActor` repo/façade action.
//
// Result contract (mirrors `app/services/assistant_tools.py`'s `AssistantToolResult`):
//   READ tools return the repo data as JSON in `resultJSON` (fed back to the model).
//   WRITE tools return a compact `{ "ok": true, "detail": … }` ack and, when they changed a
//   week, carry the changed week as `weekUpdatedJSON` (`{"week": <WeekSnapshot>}`, encoded
//   with the SimmerSmith snake_case coder) so the engine emits a `week.updated` event the UI
//   already applies. On failure a tool returns `ToolRunResult(ok: false, detail: …)` — never
//   throws into the loop (the engine surfaces `detail` verbatim per the system prompt).
//
// v1 is CURATED (~12 tools, spec §0). Deferred: exports / pricing / feedback / web-search /
// the full 49-tool MCP set — flagged as follow-ons (see the report), NOT wired here.

@MainActor
final class ToolRegistry {

    /// Weak to avoid a retain cycle (AppState owns the assistant flow that owns this).
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Engine inputs

    /// The curated tool specs handed to the provider each loop iteration.
    var specs: [ToolSpec] { Self.toolSpecs }

    /// The runner the engine calls per requested tool. `@Sendable`; dispatches by name into
    /// the matching `@MainActor` repo/façade action. A failure becomes a clean `ok:false`
    /// result rather than a thrown error so the loop can recover (system-prompt contract).
    ///
    /// C3 (review): captures `self` STRONGLY for the turn's duration. `ToolRegistry` is
    /// built as a local var in `sendAssistantMessage` and only the engine's closures hold
    /// it; a `[weak self]` capture let it deinit mid-turn (the runner would then silently
    /// fail every tool). The registry only references `AppState` weakly, so this strong
    /// self-capture can't create a retain cycle — it just pins the registry alive while
    /// the engine stream runs.
    var runner: AssistantToolRunner {
        { call in
            await self.execute(name: call.name, argsJSON: call.argsJSON)
        }
    }

    // MARK: - Dispatch

    /// Run one tool by name against the repos. Pure dispatch + error envelope; the per-tool
    /// bodies live below. Returns a failure `ToolRunResult` for an unknown tool.
    private func execute(name: String, argsJSON: String) async -> ToolRunResult {
        guard let appState else {
            return Self.failure("The assistant isn't ready yet.")
        }
        let args = Self.decodeArgs(argsJSON)
        switch name {
        // Reads
        case "recipes_list":             return recipesList(args, appState)
        case "recipes_get":              return recipesGet(args, appState)
        case "weeks_get_current":        return weeksGetCurrent(appState)
        case "weeks_get":                return weeksGet(args, appState)
        case "pantry_list":              return pantryList(appState)
        case "grocery_get":              return groceryGet(args, appState)
        // Writes
        case "recipes_save":             return await recipesSave(args, appState)
        case "weeks_update_meals":       return await weeksUpdateMeals(args, appState)
        case "weeks_apply_ai_draft":     return await weeksApplyAIDraft(args, appState)
        case "weeks_regenerate_grocery": return await weeksRegenerateGrocery(args, appState)
        case "recipes_suggestion_draft": return await recipesSuggestionDraft(args, appState)
        case "recipes_variation_draft":  return await recipesVariationDraft(args, appState)
        default:
            return Self.failure("Unknown tool: \(name)")
        }
    }

    // MARK: - READ tools

    /// recipes_list — all recipes (optionally including archived / filtered by cuisine,
    /// tags). Ports `app/mcp/recipes.py::recipes_list`. Returns the repo's RecipeSummary list.
    private func recipesList(_ args: [String: Any], _ appState: AppState) -> ToolRunResult {
        let includeArchived = (args["include_archived"] as? Bool) ?? false
        let cuisine = (args["cuisine"] as? String) ?? ""
        let tags = (args["tags"] as? [String]) ?? []
        var recipes = appState.recipes
        if !includeArchived { recipes = recipes.filter { !$0.archived } }
        if !cuisine.isEmpty {
            recipes = recipes.filter { $0.cuisine.caseInsensitiveCompare(cuisine) == .orderedSame }
        }
        if !tags.isEmpty {
            let wanted = Set(tags.map { $0.lowercased() })
            recipes = recipes.filter { recipe in
                !Set(recipe.tags.map { $0.lowercased() }).isDisjoint(with: wanted)
            }
        }
        return success(encodeJSON(["recipes": recipes]))
    }

    /// recipes_get — one recipe by id. Ports `recipes.py::recipes_get`.
    private func recipesGet(_ args: [String: Any], _ appState: AppState) -> ToolRunResult {
        guard let recipeID = args["recipe_id"] as? String, !recipeID.isEmpty else {
            return Self.failure("recipe_id is required.")
        }
        guard let recipe = appState.recipes.first(where: { $0.recipeId == recipeID }) else {
            return Self.failure("Recipe \(recipeID) not found.")
        }
        return success(encodeJSON(["recipe": recipe]))
    }

    /// weeks_get_current — the active week. Ports `weeks.py::weeks_get_current`.
    private func weeksGetCurrent(_ appState: AppState) -> ToolRunResult {
        guard let week = appState.currentWeek else {
            return success(#"{"week":null}"#)
        }
        // In CloudKit mode, only surface a week the repository can actually resolve —
        // otherwise the model receives a week_id that every write tool rejects with
        // "Week not found" (currentWeek can briefly hold a Fly-sourced / cached id not
        // in this store). Return the repo's fresh snapshot. Fly-only mode (no repo)
        // keeps the legacy behavior.
        if let repo = appState.weekRepository {
            guard let resolved = repo.week(forId: week.weekId) else {
                return success(#"{"week":null}"#)
            }
            return success(encodeWeekResult(resolved))
        }
        return success(encodeWeekResult(week))
    }

    /// weeks_get — a week by id. Ports `weeks.py::weeks_get`.
    private func weeksGet(_ args: [String: Any], _ appState: AppState) -> ToolRunResult {
        guard let weekID = args["week_id"] as? String, !weekID.isEmpty else {
            return Self.failure("week_id is required.")
        }
        guard let week = appState.weekRepository?.week(forId: weekID) else {
            return Self.failure("Week \(weekID) not found.")
        }
        return success(encodeWeekResult(week))
    }

    /// pantry_list — the household's active pantry items. Mirrors the server pantry list.
    private func pantryList(_ appState: AppState) -> ToolRunResult {
        let items = appState.pantryRepository?.pantryItems ?? []
        return success(encodeJSON(["pantry_items": items]))
    }

    /// grocery_get — a week's live grocery list. Reads the snapshot's grocery rows
    /// (WeekRepository assembles them); defaults to the current week when no id is given.
    private func groceryGet(_ args: [String: Any], _ appState: AppState) -> ToolRunResult {
        let weekID = (args["week_id"] as? String) ?? ""
        let week: WeekSnapshot?
        if !weekID.isEmpty {
            week = appState.weekRepository?.week(forId: weekID) ?? appState.currentWeek
        } else {
            week = appState.currentWeek
        }
        guard let resolved = week else {
            return Self.failure("No active week. Create one first.")
        }
        return success(encodeJSON([
            "week_id": resolved.weekId,
            "grocery_items": resolved.groceryItems,
        ]))
    }

    // MARK: - WRITE tools

    /// recipes_save — create/update a recipe. Decodes a snake_case recipe object into a
    /// `RecipeDraft` (the on-device equivalent of the server's `RecipePayload`) and saves it
    /// through `AppState.saveRecipe` → RecipeRepository (CloudKit) + mirror. Ports
    /// `recipes.py::recipes_save`.
    private func recipesSave(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        // The model may pass the recipe nested (`{"recipe": {…}}`) or flat — accept both.
        let recipeObject = (args["recipe"] as? [String: Any]) ?? args
        guard appState.recipeRepository != nil else {
            return Self.failure("Recipes need iCloud — try again after sync finishes.")
        }
        let draft: RecipeDraft
        do {
            draft = try Self.decodeDraft(recipeObject)
        } catch {
            return Self.failure("Could not read the recipe payload: \(Self.decodeReason(error)).")
        }
        do {
            let saved = try await appState.saveRecipe(draft)
            return success(
                encodeJSON(["recipe": saved]),
                detail: "Saved \"\(saved.name)\"."
            )
        } catch {
            return Self.failure("Save failed: \(Self.message(for: error))")
        }
    }

    /// weeks_update_meals — MERGE-only edit of a week's meals (simmersmith-enx: data-loss
    /// fix). `WeekRepository.saveWeekMeals` deletes a stored `.weekMeal` only if the caller KNEW
    /// it and dropped it (baseline-aware since eky) — so this handler reads the week's CURRENT meals first,
    /// folds the model's payload into them via `MealMergeResolver.fold` (upsert by
    /// day+slot; an empty `recipe_name` clears that one slot; every other slot is left
    /// untouched), and only then writes the merged full set. Mirrors the voice path's
    /// identical fix (`VoicePlanResolver.merge`). Ports `weeks.py::weeks_update_meals`.
    private func weeksUpdateMeals(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        guard let weekID = args["week_id"] as? String, !weekID.isEmpty else {
            return Self.failure("week_id is required.")
        }
        guard let repo = appState.weekRepository else {
            return Self.failure("Weeks need iCloud — try again after sync finishes.")
        }
        guard let mealsRaw = args["meals"] as? [[String: Any]] else {
            return Self.failure("meals must be a list.")
        }
        let updates: [MealUpdateRequest]
        do {
            updates = try Self.decodeMeals(mealsRaw)
        } catch {
            return Self.failure("Could not read the meals payload: \(Self.decodeReason(error)).")
        }
        guard let currentWeek = repo.week(forId: weekID) else {
            return Self.failure("Week \(weekID) not found.")
        }
        let existing = currentWeek.meals.map { $0.asMealUpdateRequest() }
        let merged = MealMergeResolver.fold(updates: updates, into: existing)
        do {
            // knownMealIDs: the `existing` meals fetched above — the current-week snapshot
            // `merged` was folded into. An explicit CLEAR (fold-removed slot) is known + absent
            // from `merged` → deleted; a concurrent add this fetch never saw → kept.
            let week = try await appState.saveWeekMeals(
                weekID: weekID, meals: merged, knownMealIDs: Set(existing.compactMap { $0.mealId })
            )
            return success(
                encodeWeekResult(week),
                detail: "Updated the meals for the week.",
                week: week
            )
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    /// weeks_apply_ai_draft — generate + apply a full week plan (→ the AI-1 week-gen path).
    /// Ports `weeks.py::weeks_apply_ai_draft`; on-device this IS the generation (the server
    /// pre-generated the draft, here `generateWeek` does the LLM call + apply + regen).
    private func weeksApplyAIDraft(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        guard let weekID = args["week_id"] as? String, !weekID.isEmpty else {
            return Self.failure("week_id is required.")
        }
        let prompt = (args["prompt"] as? String) ?? ""
        do {
            let week = try await appState.generateWeek(weekID: weekID, prompt: prompt)
            return success(
                encodeWeekResult(week),
                detail: "Generated and applied a plan for the week.",
                week: week
            )
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    /// weeks_regenerate_grocery — rebuild the week's grocery list. Ports
    /// `weeks.py::weeks_regenerate_grocery`.
    private func weeksRegenerateGrocery(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        guard let weekID = args["week_id"] as? String, !weekID.isEmpty else {
            return Self.failure("week_id is required.")
        }
        do {
            let week = try await appState.regenerateGrocery(weekID: weekID)
            return success(
                encodeWeekResult(week),
                detail: "Regenerated the grocery list.",
                week: week
            )
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    /// recipes_suggestion_draft — an AI recipe suggestion (→ AI-2). Returns a DRAFT for the
    /// user to review (not saved). Ports `recipes.py::recipes_suggestion_draft`.
    private func recipesSuggestionDraft(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        let goal = (args["goal"] as? String) ?? ""
        do {
            let draft = try await appState.generateRecipeSuggestionDraft(goal: goal)
            return success(
                encodeJSON(["goal": draft.goal, "rationale": draft.rationale, "recipe": draft.draft]),
                detail: "Drafted \"\(draft.draft.name)\" — review and save it."
            )
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    /// recipes_variation_draft — an AI variation of an existing recipe (→ AI-2). Returns a
    /// DRAFT. Ports `recipes.py::recipes_variation_draft`.
    private func recipesVariationDraft(_ args: [String: Any], _ appState: AppState) async -> ToolRunResult {
        guard let recipeID = args["recipe_id"] as? String, !recipeID.isEmpty else {
            return Self.failure("recipe_id is required.")
        }
        let goal = (args["goal"] as? String) ?? ""
        do {
            let draft = try await appState.generateRecipeVariationDraft(recipeID: recipeID, goal: goal)
            return success(
                encodeJSON(["goal": draft.goal, "rationale": draft.rationale, "recipe": draft.draft]),
                detail: "Drafted a variation: \"\(draft.draft.name)\" — review and save it."
            )
        } catch {
            return Self.failure(Self.message(for: error))
        }
    }

    // MARK: - Encoding helpers

    /// Encode a `[String: Any]`-style payload into one JSON object. Encodable domain values
    /// go through the SimmerSmith coder (snake_case — matches the server tool JSON the model
    /// expects + the UI's `convertFromSnakeCase` decode for week.updated); scalars pass
    /// through. Heterogeneous payloads (`{"recipes": […], "week_id": …}`) serialize correctly.
    private func encodeJSON(_ dict: [String: Any]) -> String {
        var object: [String: Any] = [:]
        for (key, value) in dict {
            object[key] = jsonFragment(value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    /// Turn one heterogeneous value into a Foundation JSON fragment. Encodable domain values
    /// go through the SimmerSmith coder (snake_case); scalars/arrays/null pass through.
    private func jsonFragment(_ value: Any) -> Any {
        switch value {
        case let s as String: return s
        case let i as Int: return i
        case let d as Double: return d
        case let b as Bool: return b
        case is NSNull: return NSNull()
        case let arr as [WeekMeal]: return decodeFragment(arr)
        case let arr as [RecipeSummary]: return decodeFragment(arr)
        case let arr as [PantryItem]: return decodeFragment(arr)
        case let arr as [GroceryItem]: return decodeFragment(arr)
        case let recipe as RecipeSummary: return decodeFragment(recipe)
        case let draft as RecipeDraft: return decodeFragment(draft)
        case let week as WeekSnapshot: return decodeFragment(week)
        default: return NSNull()
        }
    }

    /// Encode an Encodable through the SimmerSmith coder, then decode back to a Foundation
    /// JSON object/array so it can be embedded inside a larger `JSONSerialization` payload.
    private func decodeFragment<T: Encodable>(_ value: T) -> Any {
        guard let data = try? SimmerSmithJSONCoding.makeEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return NSNull() }
        return obj
    }

    /// Encode a `WeekSnapshot` as the model-facing `{"week": <snapshot>}` result string.
    private func encodeWeekResult(_ week: WeekSnapshot) -> String {
        encodeJSON(["week": week])
    }

    // MARK: - Result builders (mirror AssistantToolResult)

    /// A successful tool result. `week`, when present, is encoded as `{"week": …}` for the
    /// engine's `week.updated` emission (the UI decodes it via `convertFromSnakeCase`).
    /// `nonisolated`-friendly: the week encode happens here (instance) and the plain ack is
    /// built by the `nonisolated` static `ok` so the runner closure can build failures too.
    private func success(
        _ resultJSON: String,
        detail: String = "",
        week: WeekSnapshot? = nil
    ) -> ToolRunResult {
        Self.ok(resultJSON, detail: detail, weekJSON: week.map { encodeJSON(["week": $0]) })
    }

    nonisolated private static func ok(
        _ resultJSON: String,
        detail: String,
        weekJSON: String?
    ) -> ToolRunResult {
        ToolRunResult(resultJSON: resultJSON, ok: true, detail: detail, weekUpdatedJSON: weekJSON)
    }

    nonisolated static func failure(_ detail: String) -> ToolRunResult {
        ToolRunResult(resultJSON: errorBody(detail), ok: false, detail: detail)
    }

    nonisolated private static func errorBody(_ detail: String) -> String {
        let object: [String: Any] = ["ok": false, "detail": detail]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8)
        else { return #"{"ok":false}"# }
        return str
    }

    /// A user-facing message for a thrown tool error (AI / repo failures). Prefers a
    /// `LocalizedError` description; never leaks a key/raw body.
    nonisolated private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Arg decoding

    private static func decodeArgs(_ argsJSON: String) -> [String: Any] {
        guard let data = argsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Decode a snake_case recipe object into a `RecipeDraft` via the SimmerSmith coder.
    /// Throws so the caller can surface *why* a payload failed (which field / wrong type)
    /// instead of an opaque "Could not read the recipe payload" — the model occasionally
    /// emits e.g. ingredients/steps as plain strings, which `decodeIfPresent` rejects.
    private static func decodeDraft(_ object: [String: Any]) throws -> RecipeDraft {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try SimmerSmithJSONCoding.makeDecoder().decode(RecipeDraft.self, from: data)
    }

    /// Decode a snake_case meals array into `[MealUpdateRequest]` via the SimmerSmith coder.
    private static func decodeMeals(_ array: [[String: Any]]) throws -> [MealUpdateRequest] {
        let data = try JSONSerialization.data(withJSONObject: array)
        return try SimmerSmithJSONCoding.makeDecoder().decode([MealUpdateRequest].self, from: data)
    }

    /// A concise, human-readable reason for a decode failure: which field and what went
    /// wrong. Used to turn "Could not read the recipe payload." into something diagnosable.
    nonisolated static func decodeReason(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return Self.message(for: error) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        }
        switch decoding {
        case let .keyNotFound(key, _):
            return "missing required field '\(key.stringValue)'"
        case let .typeMismatch(_, context):
            let field = path(context)
            return field.isEmpty ? "a field has the wrong type" : "wrong type for '\(field)'"
        case let .valueNotFound(_, context):
            let field = path(context)
            return field.isEmpty ? "a required field was null" : "'\(field)' was null"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return "the payload could not be read"
        }
    }

    // MARK: - The curated tool specs (ported from app/mcp/*)

    private static let toolSpecs: [ToolSpec] = [
        ToolSpec(
            name: "recipes_list",
            description: "List the household's recipes. Optionally include archived recipes, or filter by cuisine or tags.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"include_archived":{"type":"boolean","description":"Include archived recipes."},"cuisine":{"type":"string","description":"Filter to one cuisine."},"tags":{"type":"array","items":{"type":"string"},"description":"Filter to recipes carrying any of these tags."}}}
            """
        ),
        ToolSpec(
            name: "recipes_get",
            description: "Get one recipe by its id, including ingredients and steps.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"recipe_id":{"type":"string"}},"required":["recipe_id"]}
            """
        ),
        ToolSpec(
            name: "recipes_save",
            description: "Create or update a recipe. Pass the full recipe object (name, ingredients, steps, etc.). Include recipe_id to update an existing recipe.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"recipe":{"type":"object","description":"The recipe payload: name, meal_type, cuisine, servings, ingredients[], steps[], notes, tags[]. Include recipe_id to update."}},"required":["recipe"]}
            """
        ),
        ToolSpec(
            name: "weeks_get_current",
            description: "Get the user's current week with its meals and grocery list.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        ),
        ToolSpec(
            name: "weeks_get",
            description: "Get a week by its id, with meals and grocery list.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"week_id":{"type":"string"}},"required":["week_id"]}
            """
        ),
        ToolSpec(
            name: "weeks_update_meals",
            description: "MERGE edit for a week's meals — send ONLY the meals you want to add or change, one entry per (day_name, slot). Every other slot in the week is left untouched; do NOT resend the whole week. To clear a single slot (remove its meal), send that slot with an empty recipe_name. The grocery list regenerates automatically.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"week_id":{"type":"string"},"meals":{"type":"array","items":{"type":"object","properties":{"meal_id":{"type":"string"},"day_name":{"type":"string"},"meal_date":{"type":"string","description":"ISO date YYYY-MM-DD."},"slot":{"type":"string","description":"breakfast | lunch | dinner."},"recipe_id":{"type":"string"},"recipe_name":{"type":"string","description":"Empty string clears this slot's meal."},"servings":{"type":"number"},"notes":{"type":"string"}},"required":["day_name","meal_date","slot","recipe_name"]},"description":"ONLY the (day,slot) meals to add/change/clear — never the full week."}},"required":["week_id","meals"]}
            """
        ),
        ToolSpec(
            name: "weeks_apply_ai_draft",
            description: "Generate and apply a full AI meal plan for a week from a natural-language prompt (e.g. 'a quick vegetarian week'). Replaces the week's meals and regenerates grocery. Use ONLY for a full week plan/reset; for small edits use weeks_update_meals.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"week_id":{"type":"string"},"prompt":{"type":"string","description":"What kind of week to plan."}},"required":["week_id","prompt"]}
            """
        ),
        ToolSpec(
            name: "weeks_regenerate_grocery",
            description: "Regenerate the grocery list for a week from its current meals. Preserves user-added items, checks, and overrides.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"week_id":{"type":"string"}},"required":["week_id"]}
            """
        ),
        ToolSpec(
            name: "recipes_suggestion_draft",
            description: "Generate a new recipe DRAFT from a goal (e.g. 'a hearty fall soup'). Returns a draft for the user to review and save — it is NOT saved automatically.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"goal":{"type":"string"}},"required":["goal"]}
            """
        ),
        ToolSpec(
            name: "recipes_variation_draft",
            description: "Generate a variation DRAFT of an existing recipe toward a goal (e.g. 'make it vegetarian'). Returns a draft for the user to review and save — it is NOT saved automatically.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"recipe_id":{"type":"string"},"goal":{"type":"string"}},"required":["recipe_id","goal"]}
            """
        ),
        ToolSpec(
            name: "pantry_list",
            description: "List the household's active pantry staples.",
            parametersSchemaJSON: #"{"type":"object","properties":{}}"#
        ),
        ToolSpec(
            name: "grocery_get",
            description: "Get a week's grocery list. Defaults to the current week when week_id is omitted.",
            parametersSchemaJSON: """
            {"type":"object","properties":{"week_id":{"type":"string"}}}
            """
        ),
    ]
}
#endif
