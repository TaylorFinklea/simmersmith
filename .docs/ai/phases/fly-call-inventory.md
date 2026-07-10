# Fly-call inventory — every production `apiClient.*` call site, classified

> Bead `simmersmith-8xz`. 2026-07-09. Four agents enumerated **140** call sites, each reading the
> full enclosing function and every early-return above it. Every LIVE-AND-BROKEN row was then given to
> an independent verifier told to **refute** it — 3 of 24 were demoted. Fable spot-checked two
> refutations against the code and upheld both.
>
> **This supersedes ADR-1's prose list of seven Fly-backed features**, which omitted meal feedback
> (`b9z`), grocery feedback, and Plan Shopping (`4ii`). Bead `990.8` must strip from THIS table.

| class | count | meaning |
|---|---|---|
| **LIVE-AND-BROKEN** | **21** | reachable on a CloudKit household; hits the dead backend. **Gate-2: port or hide.** |
| GUARDED-DEAD | 73 | a CloudKit branch (or an unreachable UI path) returns first. Safe for `990.8` to strip. |
| PORTED-ALREADY | 46 | CloudKit impl exists; the call is a legacy `hasSavedConnection` fallback. |
| **total** | **140** | |

## LIVE-AND-BROKEN — the Gate-2 set (each adversarially verified)

Each row is a visible feature that lies. Grouped by the bead that owns it.

### Feedback loop → bead `b9z`

| method | site | user entry point |
|---|---|---|
| `submitFeedback` | `App/AppState+Weeks.swift:578` | Features/Week/WeekView.swift:417 inside .sheet(item: $feedbackMeal) { meal in FeedbackComposerView(title: meal |
| `submitFeedback` | `App/AppState+Weeks.swift:602` | GroceryView.swift:224-226 swipe-action 'Feedback' button on a grocery-item row -> sets selectedItem -> Grocery |

### Plan Shopping → bead `4ii`

| method | site | user entry point |
|---|---|---|
| `planShopping` | `App/AppState+Grocery.swift:183` | Two confirmed non-DEBUG paths: (1) Features/Week/WeekView.swift:1595-1598 planShoppingTrailing button ("plan"  |

### Recipe memories → bead `990.4.2`

| method | site | user entry point |
|---|---|---|
| `fetchRecipeMemories` | `App/AppState+Recipes.swift:1169` | Features/Recipes/RecipeMemoriesSection.swift:135 (load(), fired by .task(id: recipeID) on RecipeMemoriesSectio |
| `createRecipeMemory` | `App/AppState+Recipes.swift:1184` | Features/Recipes/MemoryComposeSheet.swift:115 (save()), sheet presented via RecipeMemoriesSection.swift:64-66  |
| `deleteRecipeMemory` | `App/AppState+Recipes.swift:1207` | Features/Recipes/RecipeMemoriesSection.swift:144 (delete(_:) called from the confirmationDialog's Delete butto |

### Ingredients / nutrition → beads `990.5.1` · `990.5.2`

The largest cluster (15 of 21). `990.5.1`'s note already called `IngredientLinkPickerSheet`
"fully dead-backend"; this is its full extent.

| method | site | user entry point |
|---|---|---|
| `fetchBaseIngredients` | `App/AppState+Ingredients.swift:14` | Confirmed reachable (5 of 6 claimed sites): Features/Ingredients/IngredientsView.swift:91 (loadIngredients, vi |
| `fetchIngredientVariations` | `App/AppState+Ingredients.swift:26` | Confirmed both: (1) Features/Settings/SettingsView.swift:1190 inside IngredientPreferenceEditorSheet.selectBas |
| `fetchBaseIngredientDetail` | `App/AppState+Ingredients.swift:30` | Features/Ingredients/IngredientsView.swift:388 (IngredientDetailView.loadDetail, run from .task(id: reloadToke |
| `createBaseIngredient` | `App/AppState+Ingredients.swift:48` | Confirmed both: (1) Features/Ingredients/IngredientsView.swift:593 inside BaseIngredientEditorSheet.save() (cr |
| `updateBaseIngredient` | `App/AppState+Ingredients.swift:81` | Confirmed as claimed: IngredientsView.swift:580 (BaseIngredientEditorSheet.save, edit path). Full reachable ch |
| `archiveBaseIngredient` | `App/AppState+Ingredients.swift:100` | Features/Ingredients/IngredientsView.swift:154 — IngredientDetailView's toolbar Menu(\"Manage\") > \"Archive\" |
| `mergeBaseIngredient` | `App/AppState+Ingredients.swift:104` | Confirmed as claimed: Features/Ingredients/BaseIngredientMergeSheet.swift:131 (merge()), reached via Settings  |
| `createIngredientVariation` | `App/AppState+Ingredients.swift:127` | Confirmed as claimed, both entry points: (1) Features/Ingredients/IngredientsView.swift:757 (IngredientVariati |
| `updateIngredientVariation` | `App/AppState+Ingredients.swift:170` | Features/Settings/SettingsView.swift:479 ("Manage Ingredient Catalog" NavigationLink, ungated) → Features/Ingr |
| `archiveIngredientVariation` | `App/AppState+Ingredients.swift:194` | Features/Settings/SettingsView.swift:479-483 (unconditional NavigationLink "Manage Ingredient Catalog") → Feat |
| `resolveIngredient` | `App/AppState+Ingredients.swift:202` | Confirmed as claimed: RecipeEditorView.swift:307-322 (unconditional "Review ingredient match"/"Change ingredie |
| `fetchBaseIngredients` | `App/AppState+Recipes.swift:1875` | Confirmed as claimed: Features/Grocery/IngredientLinkPickerSheet.swift:178 (search()), auto-triggered uncondit |
| `createBaseIngredient` | `Features/Grocery/IngredientLinkPickerSheet.swift:192` | Confirmed all three: Features/Grocery/GroceryFeedbackSheet.swift:136, Features/Grocery/GroceryItemEditSheet.sw |
| `patchGroceryItem` | `Features/Grocery/IngredientLinkPickerSheet.swift:212` | Confirmed via grep: exactly three presenter sites outside the view's own definition — Features/Grocery/Grocery |
| `submitIngredientForAdoption` | `Features/Ingredients/IngredientsView.swift:564` | Features/Settings/SettingsView.swift:479-483 (NavigationLink → IngredientsView()) → tap any ingredient row (Fe |

## Demoted on verification — do NOT bead these

Enumerated as live (the function truly has no guard) but **refuted**: no user action reaches them.
Recorded so nobody re-files them.

| method | why it is not reachable |
|---|---|
| `mergeIngredientVariation` | **No caller at all.** Repo-wide grep finds only its own declaration. Dead code — `990.5.1` should DELETE it, not port it. |
| `saveIngredientNutritionMatch` | Both presenters of `RecipeNutritionMatchView` are gated. `RecipeDetailView:722` guards on `!isCloudKitOnly`; the editor path renders its buttons only inside `if let nutritionSummary`, and `refreshNutritionEstimate` nils that summary in CloudKit-only mode. Fable independently re-checked this one — the gate is real. |
| `fetchRecipeMemoryPhotoBytes` | Reached only from a memory row that a live `fetchRecipeMemories` must first return; that call is itself live-and-broken, so the photo fetch is unreachable in practice. Fixed transitively by `990.4.2`. |

## GUARDED-DEAD and PORTED-ALREADY

The remaining 119 rows are safe. `990.8` strips only the GUARDED-DEAD set; the PORTED-ALREADY rows
are legacy `hasSavedConnection` fallbacks and die with the migration bridge (`990.9`). The raw
per-row classification lives in the workflow journal (`wf_bbf1865d-0ad`); it is reproducible by
re-running the audit rather than trusting this prose.


---

## Appendix — verbatim evidence for selected LIVE-AND-BROKEN rows

> Written by the audit agents during enumeration: the full enclosing function body and the
> traced user entry point, unabridged. Not exhaustive — the authoritative, complete
> classification is the table above. Kept because re-deriving a guard's absence from memory
> is exactly the mistake that produced ADR-1's wrong list.

## Row: apiClient.fetchBaseIngredients (AppState+Ingredients.swift:14, searchBaseIngredients)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Ingredients.swift:14`,
  inside `searchBaseIngredients(query:limit:includeArchived:provisionalOnly:
  withPreferences:withVariations:includeProductLike:)` (lines 5-23, entire
  function read).
- **Full function body** (verbatim, no truncation):
  ```swift
  func searchBaseIngredients(
      query: String = "",
      limit: Int = 20,
      includeArchived: Bool = false,
      provisionalOnly: Bool = false,
      withPreferences: Bool = false,
      withVariations: Bool = false,
      includeProductLike: Bool = false
  ) async throws -> [BaseIngredient] {
      try await apiClient.fetchBaseIngredients(
          query: query,
          limit: limit,
          includeArchived: includeArchived,
          provisionalOnly: provisionalOnly,
          withPreferences: withPreferences,
          withVariations: withVariations,
          includeProductLike: includeProductLike
      )
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard (no
  `preferenceRepository`/other repo reference at all), no
  `hasSavedConnection` check — the apiClient call IS the entire body,
  unconditional. Same class of gap as the `updateBaseIngredient` /
  `fetchBaseIngredientDetail` / `archiveBaseIngredient` rows above, same
  file: the very next function, `refreshIngredientPreferences()` (lines
  209-224), DOES have both the `#if canImport(CloudKit)` +
  `preferenceRepository` branch AND a `guard hasSavedConnection else {
  return }` before its own Fly fallback, confirming the omission here is a
  gap against this file's own established pattern, not a deliberate
  "no guard needed" design.
- **Caller grep**: `grep -rn "searchBaseIngredients"` across
  `SimmerSmith/SimmerSmith` finds six call sites outside the definition:
  1. `Features/Ingredients/IngredientsView.swift:91`, inside
     `loadIngredients()` (lines 87-104).
  2. `Features/Settings/SettingsView.swift:1165`, inside
     `loadInitialState()` (lines 1161-1173) of `IngredientPreferenceEditorSheet`.
  3. `Features/Settings/SettingsView.swift:1179`, inside
     `searchIngredients()` (lines 1175-1184), same sheet.
  4. `Features/Settings/SettingsView.swift:1330`, inside
     `loadIngredients()` (lines 1326-1335) of `IngredientCatalogSheet`.
  5. `Features/Ingredients/BaseIngredientMergeSheet.swift:114`, inside
     `loadCandidates()` (lines 110-124).
  6. `Features/Recipes/RecipeEditorIngredientResolution.swift:390`, inside
     `searchIngredients()` (lines 386-403) of `IngredientResolutionSheet`.
  None of the six enclosing functions has a CloudKit/`hasSavedConnection`
  guard before the call.
- **Reachability — confirmed for 5 of 6 sites, one refuted**:
  - **(1) IngredientsView.swift:91**: `.task(id: loadKey)` on the view's
    root (`IngredientsView.swift:66-68`) calls `loadIngredients()`
    unconditionally whenever the view appears/`loadKey` changes.
    `IngredientsView` is pushed from `SettingsView.swift:479-483`
    (`NavigationLink { IngredientsView() } label: { Label("Manage
    Ingredient Catalog", ...) }`), a plain top-level `Form { Section {...}
    }` entry with no enclosing `if`/`#if canImport(CloudKit)` — the
    nearest `hasSavedConnection`/CloudKit-gated blocks in the file are
    elsewhere (e.g. an unrelated Section starting at line 629), not around
    this one. **Confirmed reachable**: Settings → "Manage Ingredient
    Catalog" → unconditional load.
  - **(2)+(3) SettingsView.swift:1165/1179**: `IngredientPreferenceEditorSheet`
    is presented via `.sheet(item: $preferenceEditor)`
    (`SettingsView.swift:657-658`), set either by tapping an existing
    preference row (`:410`) or the "Add Ingredient Preference" button
    (`:467`) — both inside the same ungated "ingredient preferences"
    `Section` (`:400-473`) as (1)'s surrounding Form. `.task { ... await
    loadInitialState() }` (`:1153-1157`) fires once per sheet presentation
    unconditionally, and the "Search Catalog" button (`:1179`'s
    `searchIngredients()`) is a plain, always-enabled button. **Confirmed
    reachable**: Settings → Ingredient Preferences editor → unconditional
    load / user-triggered search.
  - **(4) SettingsView.swift:1330 — REFUTED as a live entry point.**
    `grep -rn "IngredientCatalogSheet"` across the whole app finds exactly
    one match: the `struct IngredientCatalogSheet: View` definition itself
    (`SettingsView.swift:1239`). No `.sheet`, `NavigationLink`, or any
    other call constructs `IngredientCatalogSheet(...)` anywhere in the
    codebase — this view (and its `apiClient.fetchBaseIngredients` call at
    `:1330`) is dead code, defined but never instantiated. It also does
    NOT correspond to "Settings > Manage Ingredient Catalog" (that label
    points at `IngredientsView`, site (1) above, not `IngredientCatalogSheet`).
  - **(5) BaseIngredientMergeSheet.swift:114**: presented via
    `.sheet(isPresented: $mergePresented)` in `IngredientDetailView`
    (`IngredientsView.swift:178-181`), set by the always-visible "Merge
    Into Another Ingredient" button inside the unconditional toolbar
    `Menu("Manage")` (`IngredientsView.swift:135-137`). `IngredientDetailView`
    itself is pushed via a plain `NavigationLink` on every catalog row
    (`IngredientCatalogList.swift:26-27`), reached from (1)'s
    `IngredientsView`. `.task { if candidates.isEmpty { await
    loadCandidates() } }` (`BaseIngredientMergeSheet.swift:50-54`) fires
    unconditionally on sheet presentation. **Confirmed reachable**:
    Settings → Manage Ingredient Catalog → tap an ingredient → Manage →
    Merge Into Another Ingredient → unconditional load.
  - **(6) RecipeEditorIngredientResolution.swift:390**: presented via
    `.sheet(item: $ingredientResolutionContext)`
    (`RecipeEditorView.swift:438-442`), set by the always-visible "Review
    ingredient match" / "Change ingredient match" `Button` on every recipe
    ingredient row (`RecipeEditorView.swift:307-320`, no CloudKit/
    `hasSavedConnection` guard). `.task { guard !didLoad ...; await
    loadInitialState() }` (`RecipeEditorIngredientResolution.swift:
    290-294`) → `loadInitialState()` (`:351-359`) unconditionally calls
    `searchIngredients()` (`:386-403`, the `:390` call site). **Confirmed
    reachable**: Recipe editor → any ingredient row → Review/Change
    ingredient match → unconditional load.
- **`hasSavedConnection` semantics** (`AppState.swift:316-318`):
  `!ConnectionSettingsStore.normalizeServerURL(serverURLDraft).isEmpty` —
  `false` means no Fly server URL is configured. `buildRequest`
  (`SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  2243-2253`) throws `SimmerSmithAPIError.missingServerURL` in exactly
  that state, so on a CloudKit household with `hasSavedConnection ==
  false` every reachable call site above surfaces a caught, user-visible
  `errorMessage = error.localizedDescription` (e.g. an empty search plus
  an error banner) instead of silently working through the CloudKit
  repositories — a broken/visible-lie UX, not a silent no-op.
- **Verdict: CONFIRMED LIVE-AND-BROKEN**, with one correction to the
  claimed entry-point list: `SettingsView.swift:1330`
  (`IngredientCatalogSheet`) is dead code, never instantiated anywhere —
  drop it from the entry-point list. The other five call sites
  (`IngredientsView.swift:91`, `SettingsView.swift:1165`,
  `SettingsView.swift:1179`, `BaseIngredientMergeSheet.swift:114`,
  `RecipeEditorIngredientResolution.swift:390`) are each independently
  confirmed reachable from an ordinary, non-DEBUG user action with no
  `#if canImport(CloudKit)` block or `hasSavedConnection` guard anywhere
  between the tap and the `apiClient.fetchBaseIngredients` call — matching
  the calibration pattern (bare pass-through, no early return above the
  call) and the same-file precedent set by the `updateBaseIngredient`,
  `fetchBaseIngredientDetail`, and `archiveBaseIngredient` rows above.

## Row: apiClient.mergeBaseIngredient (AppState+Ingredients.swift:104)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Ingredients.swift:104`,
  inside `mergeBaseIngredient(sourceID:targetID:)` (lines 103-105, entire
  function read).
- **Full function body** (verbatim, the entire function):
  ```swift
  func mergeBaseIngredient(sourceID: String, targetID: String) async throws -> BaseIngredient {
      try await apiClient.mergeBaseIngredient(sourceID: sourceID, targetID: targetID)
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check — it is the entire body, called
  unconditionally. Confirmed by reading the whole file
  (`AppState+Ingredients.swift`, lines 1-317): `createBaseIngredient`,
  `updateBaseIngredient`, `archiveBaseIngredient`, `mergeBaseIngredient`,
  the variation CRUD functions, and `resolveIngredient` all lack any
  guard; only `refreshIngredientPreferences` (209-224) and
  `upsertIngredientPreference` (226-296) have the `#if canImport(CloudKit)
  if let repo = preferenceRepository { ... return }` pattern.
- **Callee confirmed real, not a stub**:
  `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  1290-1296` issues an actual `POST /api/ingredients/{sourceID}/merge`
  request via the shared `request(...)` helper.
- **Caller grep**: `grep -rn "mergeBaseIngredient"` across the repo finds
  exactly one call site outside the two definitions (`AppState+
  Ingredients.swift:104` and the API client method itself):
  `Features/Ingredients/BaseIngredientMergeSheet.swift:131`, inside
  `private func merge() async` (lines 126-138, entirely read):
  ```swift
  private func merge() async {
      guard let selectedTargetID else { return }
      do {
          isMerging = true
          errorMessage = nil
          _ = try await appState.mergeBaseIngredient(sourceID: baseIngredientID, targetID: selectedTargetID)
          onMerged()
          dismiss()
      } catch {
          errorMessage = error.localizedDescription
      }
      isMerging = false
  }
  ```
  The only guard is `guard let selectedTargetID else { return }` — a
  nil-selection bail (the user hasn't picked a merge target yet), not a
  household-type check. No CloudKit/hasSavedConnection guard precedes the
  call.
- **Reachability from `merge()` to a user action** (every hop read in
  full):
  1. `merge()` is wired to the sheet's `.confirmationAction` toolbar
     button: `Button(isMerging ? "Merging…" : "Merge") { Task { await
     merge() } }.disabled(isMerging || selectedTargetID == nil)`
     (`BaseIngredientMergeSheet.swift:41-47`) — an ordinary, always-
     compiled button, enabled once a target is selected.
  2. `BaseIngredientMergeSheet` is presented via `.sheet(isPresented:
     $mergePresented)` at `IngredientsView.swift:178-182`, inside
     `IngredientDetailView.body`.
  3. `mergePresented = true` is set from the unconditional "Merge Into
     Another Ingredient" button inside the always-visible toolbar
     `Menu("Manage")` at `IngredientsView.swift:128-144` (`if let detail`
     only gates on the detail having loaded, not on household/backend
     type; the menu button itself has no further guard).
  4. `IngredientDetailView` is pushed from `IngredientCatalogList.swift:
     26-27`, a plain `NavigationLink` inside an unconditional
     `ForEach(ingredients)` — no CloudKit/hasSavedConnection check.
  5. `IngredientCatalogList` is embedded directly in `IngredientsView.body`
     (`IngredientsView.swift:36-40`), a flat `List`, no wrapping guard.
  6. `IngredientsView` is reached via `SettingsView.swift:479-483`:
     `NavigationLink { IngredientsView() } label: { Label("Manage
     Ingredient Catalog", ...) }`, a direct sibling Section inside the flat
     top-level `Form` at `SettingsView.body` (lines 33-484, read in full).
     The only `#if canImport(CloudKit)` in this stretch (65-79) wraps an
     unrelated `SyncStatusDetailView` link inside the *first* Section and
     closes well before the ingredient-catalog Section (475-484) begins.
     The nearest `hasSavedConnection` check in the file is an unrelated
     section starting at line 629 — well after, and not an ancestor of,
     this Section.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), Settings → "Manage
  Ingredient Catalog" → tap any ingredient row → "Manage" menu → "Merge
  Into Another Ingredient" → pick a target → "Merge" unconditionally calls
  `BaseIngredientMergeSheet.merge()`, which unconditionally calls
  `appState.mergeBaseIngredient(sourceID:targetID:)`, which — with zero
  guard of any kind — calls `apiClient.mergeBaseIngredient(...)`, issuing a
  real `POST /api/ingredients/{id}/merge` against the dead Fly backend
  with no fallback path. Every hop was read in full; none contains a
  repository-nil check, `hasSavedConnection` check, or `#if
  canImport(CloudKit)` branch. Matches the claimed user entry point
  (`BaseIngredientMergeSheet.swift:131`, `merge()`) exactly, and is the
  same class of gap as the `updateBaseIngredient` / `archiveBaseIngredient`
  / `fetchBaseIngredientDetail` rows above (same file, same catalog entry
  point, same missing guard pattern).

## Row: apiClient.createBaseIngredient (AppState+Ingredients.swift:48)

- **Related bead**: simmersmith-990.5.1 ("990.5a: household-zone ingredient
  repositories + CRUD rewire", P2, open) — description states plainly
  "rewire AppState+Ingredients CRUD off apiClient," i.e. it has not
  happened yet. Independent corroboration, not the source of this row's
  evidence.
- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Ingredients.swift:48`,
  inside `createBaseIngredient(name:normalizedName:category:defaultUnit:
  notes:sourceName:sourceRecordID:sourceURL:provisional:active:
  nutritionReferenceAmount:nutritionReferenceUnit:calories:)` (lines 33-63,
  entire function read).
- **Full function body** (verbatim, no truncation):
  ```swift
  func createBaseIngredient(
      name: String,
      normalizedName: String? = nil,
      category: String = "",
      defaultUnit: String = "",
      notes: String = "",
      sourceName: String = "",
      sourceRecordID: String = "",
      sourceURL: String = "",
      provisional: Bool = false,
      active: Bool = true,
      nutritionReferenceAmount: Double? = nil,
      nutritionReferenceUnit: String = "",
      calories: Double? = nil
  ) async throws -> BaseIngredient {
      try await apiClient.createBaseIngredient(
          name: name,
          normalizedName: normalizedName,
          category: category,
          defaultUnit: defaultUnit,
          notes: notes,
          sourceName: sourceName,
          sourceRecordId: sourceRecordID,
          sourceURL: sourceURL,
          provisional: provisional,
          active: active,
          nutritionReferenceAmount: nutritionReferenceAmount,
          nutritionReferenceUnit: nutritionReferenceUnit,
          calories: calories
      )
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check anywhere in the function — it is the entire
  body, called unconditionally. Same class of gap already documented in
  this file for the sibling `updateBaseIngredient`,
  `fetchBaseIngredientDetail`, and `archiveBaseIngredient` rows (same
  file, contrast with `refreshIngredientPreferences`/
  `upsertIngredientPreference`, which do have the `#if
  canImport(CloudKit) if let repo = preferenceRepository { ... return }`
  pattern).
- **Caller grep**: `grep -rn "createBaseIngredient"` across
  `SimmerSmith/SimmerSmith` finds two call sites of the `AppState` facade
  method outside its own definition, plus one direct bypass:
  - `Features/Ingredients/IngredientsView.swift:593`, inside
    `BaseIngredientEditorSheet.save()` (lines 574-611, entirely read).
  - `Features/Recipes/RecipeEditorIngredientResolution.swift:571`, inside
    `NewBaseIngredientSheet.save()` (lines 568-583, entirely read).
  - `Features/Grocery/IngredientLinkPickerSheet.swift:192` — a third,
    previously-unfiled call site that bypasses the `AppState` facade
    entirely (`appState.apiClient.createBaseIngredient` direct). Not one
    of the two claimed entry points for this row; noted for completeness
    only. Consistent with the same file already being flagged in
    `simmersmith-990.5.1`'s notes for a sibling facade-bypass
    (`submitIngredientForAdoption` at line 564).
  Both audited callers' enclosing `save()` functions were read start to
  finish; neither has a `#if canImport(CloudKit)` block, repository-nil
  guard, or `hasSavedConnection` check anywhere above the
  `createBaseIngredient` call.
  - `BaseIngredientEditorSheet.save()`'s only branch is `if let existing =
    context.ingredient { …update path, see updateBaseIngredient row above…
    } else { …create path, this row, line 593… }` — household-type-
    agnostic.
  - `NewBaseIngredientSheet.save()` has no branch at all before the call
    (lines 568-576): `isSaving = true` then the call is the very next
    statement.
- **Reachability to a user action — entry point 1**
  (`IngredientsView.swift:593`): `IngredientsView.swift:51-58` — a plain
  toolbar `Button` ("New Ingredient", `topBarTrailing`, always visible, no
  CloudKit/hasSavedConnection gate) sets `editorContext =
  BaseIngredientEditorContext()`; the context's `init` defaults
  `ingredient` to `nil` (`IngredientsView.swift:414-421`), so `save()`'s
  `else` branch (create path, line 593) fires. `IngredientsView.swift:
  61-65` wires `.sheet(item: $editorContext) {
  BaseIngredientEditorSheet(context:...) }`. `IngredientsView` itself is
  reached via `Features/Settings/SettingsView.swift:479-483`'s
  `NavigationLink { IngredientsView() }` ("Manage Ingredient Catalog") — a
  plain, always-present link in a flat `Form`/`Section`, not behind any
  `isCloudKitOnly`/`hasSavedConnection` conditional (same Settings-entry
  verification already done for the `updateBaseIngredient`,
  `fetchBaseIngredientDetail`, and `archiveBaseIngredient` rows above).
  Full chain: Settings tab → "Manage Ingredient Catalog" → toolbar "+"
  ("New Ingredient") → fill in name → "Save" →
  `BaseIngredientEditorSheet.save()` (create branch) →
  `appState.createBaseIngredient` → `apiClient.createBaseIngredient`.
- **Reachability to a user action — entry point 2**
  (`RecipeEditorIngredientResolution.swift:571`):
  `RecipeEditorIngredientResolution.swift:187-197` — inside
  `IngredientResolutionSheet`'s "Find Canonical Ingredient" section, a
  plain `Button` labeled "Create Base Ingredient" (shown whenever a
  catalog search returns no results and the search text is non-empty; no
  CloudKit/hasSavedConnection gate) sets `newBaseIngredientContext =
  NewBaseIngredientContext(...)`; `:300` wires `.sheet(item:
  $newBaseIngredientContext) { NewBaseIngredientSheet(...) }`.
  `IngredientResolutionSheet` is presented from
  `Features/Recipes/RecipeEditorView.swift:309-319` via a plain,
  always-visible "Review ingredient match"/"Change ingredient match"
  button on every recipe-ingredient row (no gate;
  `ingredientResolutionContext = IngredientResolutionSheetContext(...)`).
  `RecipeEditorView` is reached from the Recipes tab via
  `RecipesView.swift:248`, `RecipeDetailView.swift:234`,
  `RecipeSupport.swift:463`, and `RecipeDraftReviewSheet.swift:126` — and
  Recipes is the one feature area `AppState.swift:275-280` documents by
  name as the "first (and currently only) fully cut-over" feature,
  explicitly NOT behind `ComingSoonView` (only "Weeks / Grocery / Events /
  Profile / AI" are named as gated). Full chain: Recipes tab → open/
  create a recipe → an ingredient row → "Review ingredient match" → type
  a search term with no catalog hits → "Create Base Ingredient" → fill
  in name → "Save" → `NewBaseIngredientSheet.save()` →
  `appState.createBaseIngredient` → `apiClient.createBaseIngredient`.
- **`isCloudKitOnly`/`hasSavedConnection` context confirmed**
  (`AppState.swift:280,294,316-318`): `isCloudKitOnly` is a hardcoded
  `true` compile-time constant (`private static let cloudKitOnlyBuild =
  true`), and the surrounding comment (274-279) names only "Weeks /
  Grocery / Events / Profile / AI" as gated behind `ComingSoonView`;
  Ingredients is absent from that list and is not gated anywhere in the
  navigation chain traced above, for either entry point.
  `hasSavedConnection == false` (`!ConnectionSettingsStore.
  normalizeServerURL(serverURLDraft).isEmpty`, i.e. no Fly server URL
  ever configured) is therefore the default/typical state for any
  CloudKit-only-build household, not a rare edge case.
- **Confirmed genuinely broken, not just theoretically reachable**:
  `SimmerSmithAPIClient.swift:2243-2253` (`buildRequest`, the private
  helper underlying `createBaseIngredient`'s real `POST` implementation at
  line 1197) guards `baseURLString.isEmpty` and throws
  `SimmerSmithAPIError.missingServerURL` before any network call is
  attempted — so on `hasSavedConnection == false` the call doesn't
  silently no-op or crash the app, it throws, and both `save()` callers
  catch it into `errorMessage = error.localizedDescription`
  (`IngredientsView.swift:607-609`, `RecipeEditorIngredientResolution.swift:
  579-581`). The user sees a save failure banner and the ingredient is
  never created — no CloudKit fallback exists anywhere in either chain.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), both claimed
  entry points — Ingredient Catalog's "New Ingredient" Save
  (`IngredientsView.swift:593`, `BaseIngredientEditorSheet.save`, create
  branch) and the recipe editor's "Create Base Ingredient" Save
  (`RecipeEditorIngredientResolution.swift:571`,
  `NewBaseIngredientSheet.save`) — reach `appState.createBaseIngredient`
  with zero guards above the call, which reaches
  `apiClient.createBaseIngredient` with zero guards above that either,
  which throws `missingServerURL` against the dead/unconfigured Fly
  backend. Matches bead `simmersmith-990.5.1`'s own description ("rewire
  AppState+Ingredients CRUD off apiClient" — not yet done) independently,
  without relying on the bead's text as evidence, and is the same class
  of gap as this file's `updateBaseIngredient`, `fetchBaseIngredientDetail`,
  and `archiveBaseIngredient` rows (same file, same missing-guard pattern,
  same catalog/recipe-editor entry points).

## Row: apiClient.resolveIngredient (AppState+Ingredients.swift:202)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Ingredients.swift:202`,
  inside `resolveIngredient(_:)` (lines 201-203, entire function read).
- **Full function body** (verbatim, the entire function):
  ```swift
  func resolveIngredient(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
      try await apiClient.resolveIngredient(ingredient)
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check — it is the entire body, called
  unconditionally. Re-confirmed by reading the whole file
  (`AppState+Ingredients.swift`, lines 1-317, same read as the
  `mergeBaseIngredient` row above): `resolveIngredient` sits directly below
  the variation CRUD functions with the same bare pass-through shape; only
  `refreshIngredientPreferences` (209-224) and
  `upsertIngredientPreference` (226-296), further down in the same file,
  have the `#if canImport(CloudKit) if let repo = preferenceRepository {
  ... return }` pattern.
- **Callee confirmed real, not a stub**:
  `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  1411-1425` issues an actual `POST /api/ingredients/resolve` request via
  the shared `request(...)` helper.
- **Caller grep**: `grep -rn "resolveIngredient(\|loadSuggestedResolution"`
  across `SimmerSmith/SimmerSmith/` finds exactly one call site outside the
  two definitions: `Features/Recipes/RecipeEditorIngredientResolution.swift:
  364`, inside `private func loadSuggestedResolution() async` (lines
  361-384, entirely read):
  ```swift
  private func loadSuggestedResolution() async {
      do {
          isLoadingSuggestion = true
          suggestedResolution = try await appState.resolveIngredient(ingredient)
          ...
      } catch {
          errorMessage = error.localizedDescription
      }
      isLoadingSuggestion = false
  }
  ```
  No guard of any kind precedes the call — no CloudKit check, no
  `hasSavedConnection` check, no repository check.
- **Reachability from `loadSuggestedResolution()` to a user action** (every
  hop read in full):
  1. `loadSuggestedResolution()` is called from `loadInitialState()`
     (`RecipeEditorIngredientResolution.swift:351-359`, read in full):
     `await searchIngredients(); if ingredient.baseIngredientId == nil {
     await loadSuggestedResolution() }` — the only gate is "ingredient has
     no base match yet," not a household/backend-type check.
  2. `loadInitialState()` is invoked from `IngredientResolutionSheet.body`'s
     `.task { guard !didLoad else { return }; didLoad = true; await
     loadInitialState() }` (lines 290-294) — an ordinary SwiftUI `.task`
     that fires automatically the first time the sheet renders; `didLoad`
     only prevents re-firing on view updates, it is not a CloudKit/
     `hasSavedConnection` gate. `IngredientResolutionSheet`'s `init` (lines
     103-112) and stored properties (84-101) contain no such gate either.
  3. `IngredientResolutionSheet` is presented via `.sheet(item:
     $ingredientResolutionContext)` at `RecipeEditorView.swift:438-442`,
     matching the claimed entry point exactly.
  4. `ingredientResolutionContext` is set unconditionally from the "Review
     ingredient match" / "Change ingredient match" `Button`
     (`RecipeEditorView.swift:307-322`), a plain, always-rendered button
     inside each ingredient row's `Form` section — no `if` wrapping it on
     household/backend type, no `.disabled` tied to `hasSavedConnection`.
  5. That ingredient row section sits in the ordinary recipe-editing flow
     (per-ingredient detail fields: quantity, unit, prep, category, notes,
     immediately preceding this button) — reachable by any user editing any
     recipe ingredient, CloudKit household or not.
- **`apiClient` is non-optional**: `AppState.swift:57` declares `let
  apiClient: SimmerSmithAPIClient` — always instantiated, never nil — so
  the call is a genuine network attempt, not a silent no-op. (Contrast with
  the many sibling functions in `AppState+Grocery.swift`,
  `AppState+Household.swift`, and `AppState.swift` itself that guard with
  `guard hasSavedConnection else { return }` before touching `apiClient`;
  `resolveIngredient` conspicuously has no such guard.)
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), tapping "Review
  ingredient match" / "Change ingredient match" on any unresolved recipe
  ingredient during ordinary recipe editing (`RecipeEditorView.swift:307-
  322`) presents `IngredientResolutionSheet` (`RecipeEditorView.swift:438-
  442`), whose `.task` unconditionally runs `loadInitialState()` →
  `loadSuggestedResolution()` (`RecipeEditorIngredientResolution.swift:356-
  357, 361-364`) whenever the ingredient has no `baseIngredientId` yet —
  the ordinary state for a freshly-parsed or freshly-typed ingredient. That
  call reaches `appState.resolveIngredient(ingredient)` with zero guards
  above it, which reaches `apiClient.resolveIngredient(...)` with zero
  guards above that either, issuing a real `POST /api/ingredients/resolve`
  against the dead Fly backend with no CloudKit fallback path. Every hop
  was read in full; none contains a repository-nil check,
  `hasSavedConnection` check, or `#if canImport(CloudKit)` branch. Matches
  the claimed user entry point (`RecipeEditorIngredientResolution.swift:
  364`, `loadSuggestedResolution`, sheet presented from
  `RecipeEditorView.swift:439`) exactly, and is the same class of gap as
  this file's `mergeBaseIngredient` / `createBaseIngredient` /
  `archiveBaseIngredient` rows (same file, same missing-guard pattern).

## Row: apiClient.createRecipeMemory (AppState+Recipes.swift:1184)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift:1184`,
  inside `createRecipeMemory(recipeID:body:imageData:mimeType:)` (lines
  1178-1194, entire function read).
- **Full function body** (verbatim, no truncation):
  ```swift
  func createRecipeMemory(
      recipeID: String,
      body: String,
      imageData: Data? = nil,
      mimeType: String? = nil
  ) async throws -> RecipeMemory {
      let memory = try await apiClient.createRecipeMemory(
          recipeID: recipeID,
          body: body,
          imageData: imageData,
          mimeType: mimeType
      )
      var current = recipeMemories[recipeID] ?? []
      current.insert(memory, at: 0)
      recipeMemories[recipeID] = current
      return memory
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard (no
  `recipeRepository`/other repo reference anywhere in the function), no
  `hasSavedConnection` check — the apiClient call is the first statement,
  unconditional. Confirmed by reading the surrounding "Recipe memories log
  (M15)" section in full (lines 1163-1209): the sibling
  `refreshRecipeMemories` (1168-1172), `recipeMemoriesCached` (1174-1176),
  and `deleteRecipeMemory` (1206-1209) are equally bare — none has a
  CloudKit/`hasSavedConnection` guard — while functions immediately after
  this section in the same file (`refreshRecipeMetadata`, 1211-1227;
  `createManagedListItem`, 1229-1240) DO have the established `#if
  canImport(CloudKit) if let repo = ... { ...; return }` pattern, confirming
  the omission here is a gap against this file's own convention, not a
  deliberate "no guard needed" design.
- **Caller grep**: `grep -rn "createRecipeMemory" SimmerSmith/SimmerSmith/Features/`
  finds exactly one call site outside the `AppState`/API-client definitions:
  `Features/Recipes/MemoryComposeSheet.swift:115`, inside `private func
  save() async` (lines 109-125, entirely read):
  ```swift
  private func save() async {
      let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      isSaving = true
      defer { isSaving = false }
      do {
          _ = try await appState.createRecipeMemory(
              recipeID: recipeID,
              body: trimmed,
              imageData: attachedJPEG,
              mimeType: attachedJPEG == nil ? nil : "image/jpeg"
          )
          dismiss()
      } catch {
          errorMessage = error.localizedDescription
      }
  }
  ```
  The only guard is `guard !trimmed.isEmpty else { return }` — an empty-body
  bail, not a household-type check. No CloudKit/`hasSavedConnection` guard
  precedes the call. Matches the claimed user entry point exactly.
- **Reachability from `save()` to a user action** (every hop read in full):
  1. `save()` is wired to the sheet's `.confirmationAction` toolbar button:
     `Button { Task { await save() } } ... .disabled(isSaveDisabled)`
     (`MemoryComposeSheet.swift:83-95`), where `isSaveDisabled` (104-107)
     only checks `isSaving`, `isLoadingPhoto`, and empty body text — no
     household/backend check.
  2. `MemoryComposeSheet` is presented via `.sheet(isPresented: $isComposing)
     { MemoryComposeSheet(recipeID: recipeID) }`
     (`RecipeMemoriesSection.swift:64-66`).
  3. `isComposing = true` is set unconditionally by the "+" toolbar button
     (`Button { isComposing = true } label: { Label("Add",
     systemImage: "plus.circle.fill") ... }`, `RecipeMemoriesSection.swift:
     30-38`, `.accessibilityLabel("Add memory")`) — always visible, no
     `if`/`#if canImport(CloudKit)`/`hasSavedConnection` wrapper anywhere in
     `RecipeMemoriesSection.body` (full view read, lines 22-88).
  4. `RecipeMemoriesSection(recipeID: recipe.recipeId)` is instantiated
     unconditionally at `RecipeDetailView.swift:505`, directly inside
     `RecipeDetailView`'s body — with **no** guard, in explicit contrast to
     the immediately preceding card in the same view,
     `RecipePairingsCard(recipeID:)` (line 496), which IS wrapped in `if
     !appState.isCloudKitOnly { RecipePairingsCard(...) }` (lines 493-497,
     comment: "AI pairings are Fly-backed ... Hide in CloudKit-only mode").
     `RecipeMemoriesSection` has no analogous wrapper — it renders for every
     recipe regardless of household/backend type.
  5. `RecipeDetailView` is the standard recipe detail screen, reached from
     the Recipes tab for any recipe (Recipes is the one feature area
     `AppState.swift:275-280` documents as "fully cut-over," not gated by
     `ComingSoonView`).
- **`hasSavedConnection`/CloudKit-household context confirmed** (same
  semantics as established earlier in this file, `AppState.swift:316-318`):
  `hasSavedConnection == false` (no Fly server URL ever configured) is the
  default/typical state for a CloudKit-only-build household, and
  `recipeRepository`/other household repositories are non-nil once a
  CloudKit household session exists — exactly the state named in the claim.
  In that state, `buildRequest`
  (`SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  2243-2253`) throws `SimmerSmithAPIError.missingServerURL` before any
  network call, which `MemoryComposeSheet.save()`'s `catch` surfaces as
  `errorMessage = error.localizedDescription` in the sheet's own error
  Section (`MemoryComposeSheet.swift:70-72`) — a visible save failure, not a
  silent no-op or crash.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), Recipes tab → any
  recipe → recipe detail page's "Memories" card → "+" (Add memory,
  unconditional) → compose a memory → "Save" unconditionally calls
  `MemoryComposeSheet.save()`, which unconditionally calls
  `appState.createRecipeMemory(...)`, which — with zero guard of any kind —
  calls `apiClient.createRecipeMemory(...)`, issuing a real request against
  the dead Fly backend with no CloudKit fallback path. Every hop was read
  in full; none contains a repository-nil check, `hasSavedConnection`
  check, or `#if canImport(CloudKit)` branch. Matches the claimed user
  entry point (`MemoryComposeSheet.swift:115`, presented from
  `RecipeMemoriesSection.swift`'s "+" button, unconditional) exactly.

## Row: apiClient.fetchRecipeMemories (AppState+Recipes.swift:1169, refreshRecipeMemories)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift:1169`,
  inside `refreshRecipeMemories(recipeID:)` (lines 1163-1172, entire
  function + its doc comment read).
- **Full function body** (verbatim, no truncation):
  ```swift
  // MARK: - Recipe memories log (M15)

  /// Refresh + cache the memory log for one recipe. Returns the
  /// fresh list so callers can use it directly. Caches by recipeID
  /// so navigating away/back doesn't refetch immediately.
  func refreshRecipeMemories(recipeID: String) async throws -> [RecipeMemory] {
      let memories = try await apiClient.fetchRecipeMemories(recipeID: recipeID)
      recipeMemories[recipeID] = memories
      return memories
  }
  ```
  No `#if canImport(CloudKit)` block, no `recipeRepository`/other
  repository reference, no `hasSavedConnection` check — the apiClient call
  is the entire body, unconditional. Confirmed by reading the immediately
  surrounding functions in the same file for contrast:
  `backfillRecipeImages()` (1110-1161, just above) has the full `#if
  canImport(CloudKit) if let repo = recipeRepository, let aiSvc = aiService
  { ...; return ... } #endif` pattern before its own Fly fallback;
  `refreshRecipeMetadata()` (1211-1219, just below) has both a `#if
  canImport(CloudKit) if let repo = metadataRepository { ...; return }
  #endif` block AND a `guard hasSavedConnection else { return }` before its
  Fly call. `refreshRecipeMemories` has neither — an omission against this
  file's own established pattern, not a deliberate no-guard design. The
  three sibling memory functions in the same block
  (`createRecipeMemory` :1178-1194, `fetchRecipeMemoryPhotoBytes`
  :1196-1204, `deleteRecipeMemory` :1206-1209) are equally unguarded.
- **Callee confirmed real, not a stub**:
  `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:1503-1505`:
  ```swift
  public func fetchRecipeMemories(recipeID: String) async throws -> [RecipeMemory] {
      try await request(path: "/api/recipes/\(recipeID)/memories")
  }
  ```
  an actual `GET /api/recipes/{id}/memories` via the shared `request(...)`
  helper.
- **Caller grep**: `grep -rn "refreshRecipeMemories"` across the repo finds
  exactly one call site outside the `AppState` definition itself:
  `Features/Recipes/RecipeMemoriesSection.swift:135`, inside `private func
  load() async` (lines 133-140, entirely read):
  ```swift
  private func load() async {
      do {
          _ = try await appState.refreshRecipeMemories(recipeID: recipeID)
          loadError = nil
      } catch {
          loadError = error.localizedDescription
      }
  }
  ```
  No guard of any kind before the call — `load()`'s only logic is the
  do/catch around `refreshRecipeMemories` itself.
- **`load()`'s own trigger — read the whole view file (149 lines)**:
  `RecipeMemoriesSection.body` (22-88) wires `.task(id: recipeID) { await
  load() }` (61-63) directly on the top-level `SMCard { ... }` — no
  enclosing `if`/`#if canImport(CloudKit)`/`if !appState.isCloudKitOnly`
  around either the `.task` modifier or the `body` itself. Every other
  modifier in `body` (`.sheet`, `.fullScreenCover`,
  `.confirmationDialog`) sits at the same unconditional top level.
  `isCloudKitOnly`/`hasSavedConnection` do not appear anywhere in this
  file (confirmed by reading it in full).
- **Reachability to a user action — every hop read in full**:
  1. `RecipeMemoriesSection(recipeID: recipe.recipeId)` is embedded at
     `Features/Recipes/RecipeDetailView.swift:505`, inside
     `contentSections(_:)` (437-524, entirely read) — a plain statement in
     the `VStack`, with **no** `if`/`if !appState.isCloudKitOnly` wrapper.
     Contrast confirmed directly above it in the same `VStack`: the
     AI-pairings card at line 495-497 IS wrapped (`if
     !appState.isCloudKitOnly { RecipePairingsCard(...) }`, with an inline
     comment "AI pairings are Fly-backed ... Hide in CloudKit-only mode");
     the Memories line 3 rows below has no such wrapper, matching the
     claim exactly.
  2. `contentSections(recipe)` is called unconditionally from
     `RecipeDetailView.body` (46-54, read in full): `if let recipe {
     ScrollView { VStack { headerSection(recipe); contentSections(recipe) }
     } }` — fires as soon as the recipe has loaded, for any recipe,
     independent of household/backend type.
  3. `RecipeDetailView(recipeID:)` is pushed from seven ordinary,
     always-visible navigation sites, none CloudKit/hasSavedConnection-
     gated (`grep -rn "RecipeDetailView("`): `RecipeDetailView.swift:770`
     (variant card), `RecipesView.swift:692,710,731,752,818,870` (hero
     card + list rows across the Recipes tab's different sections), and
     `Features/Week/WeekView.swift:326` (meal card in the Week tab). Recipes
     is documented in `AppState.swift:274-280` as the one feature area
     explicitly NOT behind `ComingSoonView` (only "Weeks / Grocery / Events
     / Profile / AI" are named as gated) — recipe browsing/detail is fully
     live for CloudKit-only households.
- **`hasSavedConnection` mechanics confirmed** (`AppState.swift:316-318`,
  `SimmerSmithAPIClient.swift:2243-2253`): `hasSavedConnection == false`
  means no Fly server URL configured (the default/typical state for a
  CloudKit-only household); `buildRequest` throws
  `SimmerSmithAPIError.missingServerURL` before any actual network
  attempt in that state. So concretely: the call doesn't hang or crash —
  it throws immediately, `RecipeMemoriesSection.load()` catches it into
  `loadError = error.localizedDescription`, and the Memories card renders
  a visible error line (e.g. "The operation couldn't be completed...")
  under an otherwise-empty memories list, on every single recipe detail
  page opened by a CloudKit-only household. This is the exact
  broken-but-visible-lie UX pattern already established for the other
  confirmed rows in this file.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** Matches the claim precisely:
  `refreshRecipeMemories(recipeID:)` (`AppState+Recipes.swift:1169`) has no
  guard of any kind — no `#if canImport(CloudKit)`, no repository-nil
  check, no `hasSavedConnection` check — and `RecipeMemoriesSection`
  (`RecipeMemoriesSection.swift:135`, `load()`, run from `.task(id:
  recipeID)`) is embedded unconditionally in `RecipeDetailView.swift:505`,
  three lines below the AI-pairings card that IS correctly gated behind
  `!appState.isCloudKitOnly` at line 495 — confirming the claimed contrast
  exactly. Opening any recipe detail page, from any of the seven ordinary
  navigation entry points, unconditionally fires this dead-backend call on
  a CloudKit-only household. No reclassification — the original claim
  stands as filed.

## Row: apiClient.fetchRecipeMemoryPhotoBytes (AppState+Recipes.swift:1200, fetchRecipeMemoryPhotoBytes(recipeID:memoryID:)) — REFUTED, moved to GUARDED-DEAD

- **Original claim**: LIVE-AND-BROKEN via `Features/Recipes/MemoryPhotoView.swift:34`,
  "shown for any memory row with a photo in RecipeMemoriesSection." Claimed
  evidence: "No guard."
- **Full function body** (`AppState+Recipes.swift:1196-1204`, verbatim):
  ```swift
  func fetchRecipeMemoryPhotoBytes(
      recipeID: String,
      memoryID: String
  ) async throws -> Data {
      try await apiClient.fetchRecipeMemoryPhotoBytes(
          recipeID: recipeID,
          memoryID: memoryID
      )
  }
  ```
  Confirmed: no `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check — this half of the claim is literally true, and
  matches the sibling functions in the same "Recipe memories log (M15)"
  section (`refreshRecipeMemories`, `createRecipeMemory`,
  `deleteRecipeMemory`), all equally unguarded.
- **User entry point confirmed real**: `grep -rn "fetchRecipeMemoryPhotoBytes"
  Features/` finds exactly one call site outside `AppState`:
  `Features/Recipes/MemoryPhotoView.swift:34`, inside `private func load()
  async` (lines 32-41, entire function + enclosing view read in full):
  ```swift
  private func load() async {
      do {
          imageData = try await appState.fetchRecipeMemoryPhotoBytes(
              recipeID: recipeID,
              memoryID: memoryID
          )
      } catch {
          imageData = nil
      }
  }
  ```
  wired unconditionally to `.task(id: cacheBuster ?? memoryID) { await load() }`
  (`MemoryPhotoView.swift:27-29`) — no guard in this view. `MemoryPhotoView`
  is instantiated at `Features/Recipes/RecipeMemoriesSection.swift:97`, inside
  `memoryRow(_:)` (lines 90-131, entirely read), gated only by `if
  memory.photoUrl != nil` (line 93) — a data check, not a
  household/backend check. So the claimed code path is real: **if** a memory
  with a photo exists in `appState.recipeMemories[recipeID]`, this call fires
  with zero guard. The claim is correct about every hop it names.
- **What the claim didn't check: can that precondition ever be true on a
  CloudKit household?** `memoryRow(_:)` is only invoked via
  `ForEach(memories)` (`RecipeMemoriesSection.swift:46`), where `memories`
  (`:18-20`) is `appState.recipeMemoriesCached(recipeID:) ?? []` —
  i.e. `appState.recipeMemories[recipeID] ?? []`. `recipeMemories` is a plain
  in-memory `@Published` dict (`AppState.swift:194`,
  `[String: [RecipeMemory]] = [:]`, never loaded from `cacheStore`), and it
  has exactly two writers in the whole repo (grepped
  `recipeMemories[recipeID] =` across `App/`):
  - `refreshRecipeMemories(recipeID:)` (`AppState+Recipes.swift:1168-1172`):
    `let memories = try await apiClient.fetchRecipeMemories(recipeID:
    recipeID); recipeMemories[recipeID] = memories` — the assignment is
    reached only *after* `apiClient.fetchRecipeMemories` returns
    successfully.
  - `createRecipeMemory(...)` (`:1178-1194`): same shape — `let memory = try
    await apiClient.createRecipeMemory(...)` must succeed before
    `recipeMemories[recipeID]` is ever touched.
  Both calls are themselves confirmed-LIVE-AND-BROKEN rows *elsewhere in this
  file* (see the `fetchRecipeMemories` and `createRecipeMemory` Appendix rows
  above) precisely because `buildRequest`
  (`SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  2243-2253`) throws `SimmerSmithAPIError.missingServerURL` **synchronously,
  before any network attempt**, whenever `serverURLString` is unconfigured —
  which is exactly the condition `hasSavedConnection == false` describes
  (`AppState.swift:316-318`, `hasSavedConnection` is
  `!normalizeServerURL(serverURLDraft).isEmpty`). So on the household type
  named in the claim, every attempt to populate or extend
  `recipeMemories[recipeID]` throws before the dictionary is ever written —
  `RecipeMemoriesSection.load()` (`:133-140`) catches the throw into
  `loadError` and leaves `memories` at `[]`; `MemoryComposeSheet.save()`
  (`:109-125`) catches it into `errorMessage` and never calls `dismiss()` /
  never gets a `RecipeMemory` to insert. There is no third writer: grepped
  `RecipeMemoryEntry`, `memoryPhotoBytes`, and `.memories(forRecipe` (the
  CloudKit-native equivalents defined in
  `SimmerSmith/SimmerSmith/Data/RecipeRepository.swift:46,538,593` for
  backup/restore/cascade-delete purposes) across the entire repo — they are
  referenced **only** inside `RecipeRepository.swift` itself; no `AppState`
  or `Features/` file ever calls them. Nothing else in the app can put a
  `RecipeMemory` with a `photoUrl` into `appState.recipeMemories`.
- **Reset-path check (no stale-data loophole)**: the one function that flips
  `hasSavedConnection` to `false` at runtime, `resetConnection()`
  (`AppState.swift:628-648`), also calls `clearLocalCache()`
  (`:575-626`), which explicitly resets `recipeMemories = [:]` (`:596`) in
  the same pass. So there is no reachable sequence — cold launch or
  in-session transition — that leaves `hasSavedConnection == false` with
  household repositories non-nil *and* a stale, previously-fetched
  `RecipeMemory` (with a photo) still sitting in `recipeMemories[recipeID]`.
- **Verdict: REFUTED as LIVE-AND-BROKEN, reclassified GUARDED-DEAD.** The
  claim is right that `fetchRecipeMemoryPhotoBytes` itself has no guard and
  that `MemoryPhotoView.swift:34` is a real, ungated call site — but it
  didn't check whether the *precondition* for that call site to render
  (a memory with `photoUrl != nil` in `appState.recipeMemories[recipeID]`)
  can ever be true on the named household type. It cannot: both writers to
  that dictionary are themselves Fly-only calls that throw
  `missingServerURL` synchronously before ever reaching the assignment, on
  exactly the `hasSavedConnection == false` condition named in the claim,
  with no other writer anywhere in the app. Net effect for a CloudKit
  household: the Memories card always shows either the empty state ("No
  memories yet…") or a load-error line — never a photo thumbnail — so
  `MemoryPhotoView`/`fetchRecipeMemoryPhotoBytes` is never instantiated/
  invoked in practice. This does not contradict the sibling
  `fetchRecipeMemories`/`createRecipeMemory` LIVE-AND-BROKEN verdicts
  elsewhere in this file — those calls ARE reached and DO throw against the
  dead backend every time; this one specifically requires their prior
  *success* as a precondition, which never happens.

## Row: apiClient.createIngredientVariation (AppState+Ingredients.swift:127)

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Ingredients.swift:127`,
  inside `createIngredientVariation(baseIngredientID:name:normalizedName:
  brand:upc:packageSizeAmount:packageSizeUnit:countPerPackage:productUrl:
  retailerHint:notes:sourceName:sourceRecordID:sourceURL:active:
  nutritionReferenceAmount:nutritionReferenceUnit:calories:)` (lines
  107-147, entire function read).
- **Full function body** (verbatim, the entire function, lines 107-147):
  ```swift
  func createIngredientVariation(
      baseIngredientID: String,
      name: String,
      normalizedName: String? = nil,
      brand: String = "",
      upc: String = "",
      packageSizeAmount: Double? = nil,
      packageSizeUnit: String = "",
      countPerPackage: Double? = nil,
      productUrl: String = "",
      retailerHint: String = "",
      notes: String = "",
      sourceName: String = "",
      sourceRecordID: String = "",
      sourceURL: String = "",
      active: Bool = true,
      nutritionReferenceAmount: Double? = nil,
      nutritionReferenceUnit: String = "",
      calories: Double? = nil
  ) async throws -> IngredientVariation {
      try await apiClient.createIngredientVariation(
          baseIngredientID: baseIngredientID,
          name: name,
          normalizedName: normalizedName,
          brand: brand,
          upc: upc,
          packageSizeAmount: packageSizeAmount,
          packageSizeUnit: packageSizeUnit,
          countPerPackage: countPerPackage,
          productUrl: productUrl,
          retailerHint: retailerHint,
          notes: notes,
          sourceName: sourceName,
          sourceRecordId: sourceRecordID,
          sourceURL: sourceURL,
          active: active,
          nutritionReferenceAmount: nutritionReferenceAmount,
          nutritionReferenceUnit: nutritionReferenceUnit,
          calories: calories
      )
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check — it is the entire body, called
  unconditionally. Re-confirmed by re-reading the whole file
  (`AppState+Ingredients.swift`, lines 1-317): only
  `refreshIngredientPreferences` (209-224) and
  `upsertIngredientPreference` (226-296) have the `#if canImport(CloudKit)
  if let repo = preferenceRepository { ... return }` pattern; there is no
  `variationRepository` / `IngredientVariationRepository` anywhere in the
  repo (`grep -rln "IngredientVariationRepository\|variationRepository"`
  returns nothing) — ingredient variations have no CloudKit-ported path at
  all, unlike preferences.
- **Callee confirmed real, not a stub**:
  `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  1298-1336` issues an actual `POST /api/ingredients/{baseIngredientID}/
  variations` via the shared `request(path:method:body:)` helper. That
  helper's `buildRequest` (line 2243) does
  `let baseURLString = ConnectionSettingsStore.normalizeServerURL(connection.serverURLString)`
  then `guard !baseURLString.isEmpty ... else { throw
  SimmerSmithAPIError.missingServerURL }` (lines 2249-2253) — exactly the
  state of a CloudKit-only household that never configured a Fly server
  (`hasSavedConnection == false`). The call doesn't silently no-op; it
  throws, and both callers below surface `error.localizedDescription` as
  an on-screen error banner instead of saving.
- **Caller grep**: `grep -rn "createIngredientVariation"` across
  `Features/` finds exactly two call sites, matching the claim exactly:
  `Features/Ingredients/IngredientsView.swift:757` and
  `Features/Recipes/RecipeEditorIngredientResolution.swift:666`.

  **Entry point 1 — `IngredientVariationEditorSheet.save()`**
  (`IngredientsView.swift:733-780`, entirely read):
  ```swift
  private func save() async {
      do {
          isSaving = true
          errorMessage = nil
          let saved: IngredientVariation
          if let existing = context.variation {
              saved = try await appState.updateIngredientVariation(...)
          } else {
              saved = try await appState.createIngredientVariation(   // :757
                  baseIngredientID: context.baseIngredient.baseIngredientId,
                  name: name, brand: brand, upc: upc, ...
              )
          }
          onSaved(saved)
          dismiss()
      } catch {
          errorMessage = error.localizedDescription
      }
      isSaving = false
  }
  ```
  The only branch is `if let existing = context.variation` (edit vs.
  create) — no household/backend guard. Reachability, every hop read in
  full:
  1. `save()` is wired to the sheet's `.confirmationAction` "Save" button
     (`IngredientsView.swift:721-727`):
     `Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
     .disabled(isSaving || name...isEmpty)` — an ordinary, always-compiled
     button gated only on a non-empty name.
  2. `IngredientVariationEditorSheet` is presented via `.sheet(item:
     $variationEditorContext)` (`IngredientsView.swift:170-174`), inside
     `IngredientDetailView.body`.
  3. `variationEditorContext` is set (with `variation: nil`) from the
     unconditional "Add Product Variation" button inside
     `IngredientVariationManagementSection` (`IngredientVariationManagementSection.swift:25-27`,
     `onCreateVariation` closure wired at `IngredientsView.swift:307-311`),
     itself called unconditionally from `productsSection` inside
     `detailSections` (`IngredientsView.swift:213-220`), rendered whenever
     `if let detail` (i.e., detail finished loading — not a household/backend
     check) inside `listContent` (`IngredientsView.swift:207-209`).
  4. `IngredientDetailView` is pushed from a plain `NavigationLink` inside
     an unconditional `ForEach(ingredients)` in `IngredientCatalogList.swift`
     — same hop already verified in the `mergeBaseIngredient` row above.
  5. `IngredientCatalogList` is embedded directly in `IngredientsView.body`
     (`IngredientsView.swift:36-40`), a flat `List`, no wrapping guard.
  6. `IngredientsView` is reached via `SettingsView.swift:479-483`
     (`NavigationLink { IngredientsView() } label: { Label("Manage
     Ingredient Catalog", ...) }`) — already verified unguarded in the
     `mergeBaseIngredient` row above (no `isCloudKitOnly` anywhere in
     `SettingsView.swift`; confirmed again this session via
     `grep -n "isCloudKitOnly" SettingsView.swift` → no matches).

  **Entry point 2 — `NewIngredientVariationSheet.save()`**
  (`RecipeEditorIngredientResolution.swift:663-680`, entirely read):
  ```swift
  private func save() async {
      do {
          isSaving = true
          let created = try await appState.createIngredientVariation(   // :666
              baseIngredientID: context.baseIngredient.baseIngredientId,
              name: name.trimmingCharacters(in: .whitespacesAndNewlines),
              brand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
              packageSizeAmount: Double(packageSizeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)),
              packageSizeUnit: packageSizeUnit.trimmingCharacters(in: .whitespacesAndNewlines),
              notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
          )
          onCreated(created)
          dismiss()
      } catch {
          errorMessage = error.localizedDescription
      }
      isSaving = false
  }
  ```
  No guard of any kind precedes the call. Reachability, every hop read in
  full:
  1. `save()` is wired to the sheet's `.confirmationAction` "Save" button
     (`RecipeEditorIngredientResolution.swift:651-657`), gated only on a
     non-empty name (`.disabled(isSaving || name...isEmpty)`).
  2. `NewIngredientVariationSheet` is presented via `.sheet(item:
     $newVariationContext)` (`RecipeEditorIngredientResolution.swift:
     308-316`), inside `IngredientResolutionSheet.body`.
  3. `newVariationContext` is set from the unconditional "Create Product
     Variation" button (`RecipeEditorIngredientResolution.swift:237-247`),
     inside a `Section("Product Variation")` that renders whenever `if let
     selectedBaseIngredient` (i.e., the user has picked/created a base
     ingredient to match against — not a household/backend check;
     `RecipeEditorIngredientResolution.swift:200-248`).
  4. `IngredientResolutionSheet` is presented via `.sheet(item:
     $ingredientResolutionContext)` at `RecipeEditorView.swift:438-442` —
     no wrapping guard (confirmed by reading lines 425-443; the two
     `isCloudKitOnly` guards in this file, at lines 672 and 828, are inside
     `searchIngredients(query:)` and gate the Fly-backed autocomplete
     suggestion list only, not the sheet presentation).
  5. `ingredientResolutionContext` is set from the unconditional "Review
     ingredient match" / "Change ingredient match" button
     (`RecipeEditorView.swift:307-322`), inside an unconditional
     `Section("Ingredients") { ForEach($draft.ingredients) { ... } }`
     (confirmed via `awk`/`grep` over lines 200-330: no `isCloudKitOnly`
     wraps this section) — i.e., a plain per-ingredient row control shown
     for every ingredient of every recipe being edited.
  6. `RecipeEditorView` is the ordinary recipe editor, reached by
     creating/editing any recipe — recipes are the one feature the
     `isCloudKitOnly` comment (`AppState.swift:278`) calls "fully
     cut-over," so this screen is exactly where CloudKit-household users
     spend their time.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), either (a)
  Settings → "Manage Ingredient Catalog" → tap an ingredient → "Add Product
  Variation" → fill in a name → "Save", or (b) edit any recipe → tap
  "Review ingredient match" on an ingredient row → pick/create a base
  ingredient → "Create Product Variation" → fill in a name → "Save" —
  unconditionally reaches `appState.createIngredientVariation(...)`, which
  — with zero guard of any kind — calls `apiClient.createIngredientVariation(...)`,
  which throws `SimmerSmithAPIError.missingServerURL` from `buildRequest`
  because no Fly server URL is configured. Both callers catch the error and
  merely set `errorMessage`/show a red banner — the save silently fails
  from the user's perspective (tap Save, get an error, nothing persisted).
  Every hop in both chains was read in full; none contains a repository-nil
  check, `hasSavedConnection` check, or `#if canImport(CloudKit)` branch.
  Matches both claimed user entry points exactly
  (`IngredientsView.swift:757` `IngredientVariationEditorSheet.save`;
  `RecipeEditorIngredientResolution.swift:666` `NewIngredientVariationSheet.save`),
  and is the same class of gap as the `mergeBaseIngredient` /
  `updateBaseIngredient` / `archiveBaseIngredient` rows above (same file,
  same missing-guard pattern, distinct entry points).

## Row: apiClient.saveIngredientNutritionMatch (AppState+Ingredients.swift:311, saveIngredientNutritionMatch) — REFUTED, moved to GUARDED-DEAD

- **Original claim**: LIVE-AND-BROKEN via `RecipeEditorView`'s `NutritionEditor`
  (embedded `RecipeEditorEditorView.swift:343-348`, wired to
  `presentNutritionMatcher(for:)` at `:856-864`), reached ungated (no
  `isCloudKitOnly` check anywhere in `RecipeEditorNutritionEditor.swift`),
  distinct from the already-known-gated `RecipeDetailView.swift:723` site.
- **Full function body** (`AppState+Ingredients.swift:298-316`, verbatim):
  ```swift
  func saveIngredientNutritionMatch(
      ingredientName: String,
      normalizedName: String?,
      nutritionItemID: String
  ) async throws -> IngredientNutritionMatch {
      // CATALOG TRACK: ... (comment, lines 303-310, claims the only caller,
      // RecipeNutritionMatchView, is gated behind `!isCloudKitOnly` already)
      try await apiClient.saveIngredientNutritionMatch(
          ingredientName: ingredientName,
          normalizedName: normalizedName,
          nutritionItemID: nutritionItemID
      )
  }
  ```
  Confirmed: no `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check — this part of the claim is correct, and matches
  this file's anomaly pattern (sibling functions `refreshIngredientPreferences()`
  lines 209-224 and `upsertIngredientPreference(...)` lines 226-296 both DO
  have the `#if canImport(CloudKit)`-repo-first / Fly-fallback pattern; this
  function skips straight to the Fly call).
- **Caller grep**: `grep -rn "saveIngredientNutritionMatch\|presentNutritionMatcher\|nutritionMatchContext\|onSelectUnmatchedIngredient"` across `Features/` and
  `App/` confirms exactly two UI sites construct
  `RecipeNutritionMatchContext`/present `RecipeNutritionMatchView`:
  `RecipeDetailView.swift` (already known, wrapped in `if
  !appState.isCloudKitOnly`, `:723`) and `RecipeEditorView.swift`
  (`presentNutritionMatcher(for:)` at `:856-864`, wired from
  `NutritionEditor(onSelectUnmatchedIngredient:)` at `:343-348`). Confirmed
  `RecipeEditorNutritionEditor.swift` (the `NutritionEditor` view) itself
  contains no `isCloudKitOnly` reference anywhere — this half of the claim is
  literally true.
- **The guard the claim missed**: `NutritionEditor`'s "unmatched ingredient"
  tap row (`RecipeEditorNutritionEditor.swift:41-62`) only renders inside `if
  let nutritionSummary { ... }` (line 12) — when `nutritionSummary == nil`,
  none of that section (including the tappable rows that call
  `onSelectUnmatchedIngredient`) is in the view tree at all. `nutritionSummary`
  is a `RecipeEditorView` `@State` (`:57`), and the **only** function that ever
  assigns it is `refreshNutritionEstimate(force:)` (`RecipeEditorView.swift:
  825-854`):
  ```swift
  private func refreshNutritionEstimate(force: Bool = false) async {
      // SP-C review finding D: AI nutrition estimation is Fly-backed. Skip it in
      // CloudKit-only mode; the recipe still saves (just without an auto estimate).
      guard !appState.isCloudKitOnly else {
          nutritionSummary = nil
          nutritionEstimateError = nil
          return
      }
      ... // real estimate, sets nutritionSummary = try await appState.estimateRecipeNutrition(...)
  }
  ```
  This function is called unconditionally from `.task { ...; await
  refreshNutritionEstimate(force: true) }` (`:422-426`, fires once per editor
  appearance) and `.task(id: nutritionEstimateSignature) { await
  refreshNutritionEstimate() }` (`:428-430`, refires on every ingredient
  edit) — both with no `isCloudKitOnly` wrapper of their own, i.e. they always
  run and always hit the guard when `isCloudKitOnly` is true. `isCloudKitOnly`
  (`AppState.swift:280`) is `let isCloudKitOnly: Bool =
  AppState.cloudKitOnlyBuild`, and `cloudKitOnlyBuild` (`:294`) is `private
  static let cloudKitOnlyBuild = true` — a hardcoded compile-time constant,
  currently `true` for every build/household, not a per-household runtime
  flag. So on every `RecipeEditorView` appearance and every ingredient edit,
  `refreshNutritionEstimate` deterministically forces `nutritionSummary =
  nil` before the "real" estimate path (which alone could populate
  `unmatchedIngredients`) is ever reached. Grepped every `nutritionSummary =`
  assignment in the file (`:821` only reassigns a local `prepared` copy for
  the outgoing save payload, not the `@State`; `:829`/`:838` are the two nil
  branches inside `refreshNutritionEstimate`; `:848` is the real-estimate
  branch, unreachable when `isCloudKitOnly`) — there is no other path back to
  non-nil.
  - **Residual race, not a real entry point**: if `initialDraft.nutritionSummary`
    (seeded at `:88`, e.g. a recipe imported with a pre-existing estimate)
    already carries `unmatchedIngredients`, the very first render — before
    the `.task` fires — briefly shows the tap row with a stale summary.
    `.task` starts as soon as the view appears with no `await` before the
    guard, so this window closes within (at most) one run-loop tick, well
    under human reaction time; it does not constitute a reliable,
    demonstrable user-driven path to the `apiClient` call, unlike the
    sustained, always-visible affordances confirmed for the other rows in
    this file (e.g. the `createIngredientVariation` row above).
- **Verdict: REFUTED as LIVE-AND-BROKEN, reclassified GUARDED-DEAD.** The
  in-file comment at `AppState+Ingredients.swift:308-309` is wrong about
  *which* file gates the `RecipeEditorView` path (it isn't
  `RecipeEditorNutritionEditor.swift`, and there's no `isCloudKitOnly` check
  in that file) but right about the outcome: `RecipeEditorView`'s
  nutrition-match affordance is gated too, just one layer up, via
  `refreshNutritionEstimate`'s `isCloudKitOnly` early-return forcing
  `nutritionSummary` to `nil` (same "SP-C review finding D" pattern this
  file uses elsewhere, e.g. `searchIngredients(query:)`'s `isCloudKitOnly`
  guard at `:672`). No concrete, sustained, reproducible user action reaches
  `apiClient.saveIngredientNutritionMatch` on a CloudKit household through
  either known UI site.

## Row: apiClient.patchGroceryItem (Features/Grocery/IngredientLinkPickerSheet.swift:212, link(to:))

- **Call site**: `SimmerSmith/SimmerSmith/Features/Grocery/
  IngredientLinkPickerSheet.swift:212`, inside `private func link(to base:
  BaseIngredient) async` (lines 204-224, entire function read).
- **Full function body** (verbatim, no truncation):
  ```swift
  private func link(to base: BaseIngredient) async {
      guard let weekID = appState.currentWeek?.weekId else { return }
      savingID = base.baseIngredientId
      defer { savingID = nil }
      errorMessage = nil
      var body = SimmerSmithAPIClient.GroceryItemPatchBody()
      body.baseIngredientId = .set(base.baseIngredientId)
      do {
          let updated = try await appState.apiClient.patchGroceryItem(
              weekID: weekID,
              itemID: item.groceryItemId,
              body: body
          )
          appState.replaceGroceryItemInCurrentWeek(updated)
          await appState.syncGroceryToReminders()
          onLinked?(updated)
          dismiss()
      } catch {
          errorMessage = "Couldn't link: \(error.localizedDescription)"
      }
  }
  ```
  The ONLY guard in the function is `guard let weekID = appState.currentWeek?.weekId
  else { return }` — a nil-current-week bail, not a household/backend-type
  check. No `#if canImport(CloudKit)` block, no `groceryRepository`/repository-nil
  guard, no `hasSavedConnection` check anywhere in the function — this is a
  direct `appState.apiClient.patchGroceryItem` call from a View, bypassing the
  `AppState` façade (`editGroceryItem`/`AppState+Grocery.swift`) entirely.
- **`weekID` is populated on CloudKit households too — the guard does not
  gate out the broken case**: `currentWeek` is refreshed via
  `mirrorWeekFromRepository()` (`App/AppState+Recipes.swift:429-450`), which
  reads `weekRepository.weeks` (the CloudKit-backed repository) and sets
  `currentWeek` independent of `hasSavedConnection` — confirmed by reading
  the function in full: no `hasSavedConnection` reference anywhere in it. So
  on a CloudKit household with `groceryRepository` non-nil and
  `hasSavedConnection == false`, `appState.currentWeek?.weekId` still
  resolves to a real week id; the guard passes straight through to the
  `apiClient` call.
- **Contrast with the app's own established façade pattern**: every other
  grocery-mutation entry point in `AppState+Grocery.swift` (`addGroceryItem`
  lines 9-33, `editGroceryItem` lines 39-94) follows `#if canImport(CloudKit)
  if let weekID = currentWeek?.weekId, let groceryRepo = groceryRepository {
  ...; return }` followed by `guard hasSavedConnection, let weekID =
  currentWeek?.weekId else { return }` before ever touching `apiClient`.
  `IngredientLinkPickerSheet.link(to:)` calls `appState.apiClient.
  patchGroceryItem` directly from the View layer, skipping `editGroceryItem`
  and both of those guards — the same class of façade-bypass gap already
  flagged for `createBaseIngredient` in this same file (line 192, see the
  `createBaseIngredient` row's caller-grep note above) and for
  `submitIngredientForAdoption` per bead `simmersmith-990.5.1`'s notes.
- **Callee confirmed real, not a stub**: `patchGroceryItem` issues an actual
  `PATCH /api/weeks/{weekID}/grocery/{itemID}` request through
  `SimmerSmithAPIClient`'s shared `request(...)`/`buildRequest` helper, which
  throws `SimmerSmithAPIError.missingServerURL` when `baseURLString` is empty
  (`hasSavedConnection == false`) — a genuine, user-visible failure, not a
  silent no-op.
- **Caller grep**: `grep -rn "IngredientLinkPickerSheet(" SimmerSmith/SimmerSmith/Features`
  finds exactly three presenter sites outside the view's own definition,
  matching the claim exactly:
  1. `Features/Grocery/GroceryFeedbackSheet.swift:136`
  2. `Features/Grocery/GroceryItemEditSheet.swift:104`
  3. `Features/Recipes/RecipeSupport.swift:474`
- **Reachability — entry point 1 (`GroceryFeedbackSheet.swift:136`)**, every
  hop read in full:
  1. `.sheet(isPresented: $showingLinker) { IngredientLinkPickerSheet(item:
     item) { _ in dismiss() } }` (lines 135-144) — a plain SwiftUI sheet, no
     CloudKit/`hasSavedConnection` guard around the modifier or the sheet
     body.
  2. `showingLinker = true` is set from an unconditional `Button` labeled
     "Link to Ingredient" / "Re-link to Ingredient" (lines 52-59), inside a
     plain `Section` of the feedback sheet's `Form` — no `if`/`#if
     canImport(CloudKit)`/`hasSavedConnection` wrapping the button.
  3. `GroceryFeedbackSheet` is presented via `.sheet(item:) { GroceryFeedbackSheet(item: item) }`
     from `Features/Grocery/GroceryView.swift:317` — reached from the Grocery
     tab, an ordinary always-available tab (not one of the `ComingSoonView`-
     gated feature areas named in `AppState.swift`'s `isCloudKitOnly`
     comment for Weeks/Grocery/Events/Profile/AI — Grocery's list view itself
     is live, only specific server-backed sub-actions are gated per-call).
- **Reachability — entry point 2 (`GroceryItemEditSheet.swift:104`)**: same
  shape — `.sheet(isPresented: $showingLinker) { IngredientLinkPickerSheet(item: item) { _ in dismiss() } }`
  (lines 103-111), no guard; `GroceryItemEditSheet` is presented from
  `Features/Grocery/GroceryView.swift:321` via `.sheet(item:)`, same
  Grocery-tab entry point as above.
- **Reachability — entry point 3 (`RecipeSupport.swift:474`)**: matches the
  claim; not re-traced in full here since entry points 1 and 2 already
  independently confirm the sheet is reachable via an ungated button tap from
  the Grocery tab, which is sufficient to confirm the row.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (`groceryRepository` non-nil, `hasSavedConnection == false`), Grocery tab →
  open any item's feedback/edit sheet (`GroceryFeedbackSheet` or
  `GroceryItemEditSheet`, both presented ungated from `GroceryView.swift:317`
  and `:321`) → tap "Link to Ingredient" → `IngredientLinkPickerSheet` opens,
  auto-searches, and renders results → tap any search result → `link(to:)`
  runs with its only guard (`currentWeek?.weekId`) satisfied by the
  CloudKit-populated `currentWeek` → unconditionally calls
  `appState.apiClient.patchGroceryItem(...)`, which throws
  `missingServerURL` against the dead/unconfigured Fly backend (caught into
  a visible "Couldn't link: …" error banner, `link(to:)`'s catch block) —
  the primary action of this sheet silently/visibly fails with no CloudKit
  fallback anywhere in the chain. Matches the claimed evidence and all three
  claimed user entry points exactly. Same class of gap as this file's own
  `createBaseIngredient` call at line 192 (already noted as a facade-bypass
  in the `createBaseIngredient` row above) — `IngredientLinkPickerSheet`
  bypasses the `AppState` grocery façade (`editGroceryItem`) entirely for
  both of its `apiClient` calls.

## Row: apiClient.fetchBaseIngredients (AppState+Recipes.swift:1875, fetchBaseIngredients(query:limit:))

- **Call site**: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift:1875`,
  inside `fetchBaseIngredients(query:limit:)` (lines 1872-1876, entire
  function read, plus the doc-comment above it at 1855-1871).
- **Full function body** (verbatim, no truncation):
  ```swift
  func fetchBaseIngredients(query: String, limit: Int) async throws -> [BaseIngredient] {
      // CATALOG TRACK: rewire to session.catalog (PublicCatalogReader) when the
      // Ingredient slice lands; substring search is out of scope for recipe slice 1.
      try await apiClient.fetchBaseIngredients(query: query, limit: limit)
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection`/`isCloudKitOnly` check anywhere — the apiClient call
  IS the entire body, unconditional. The preceding doc comment (1857-1871)
  independently corroborates: it explains this façade "delegates to Fly"
  "during the transition" and that the Ingredient slice/`session.catalog`
  rewire hasn't landed yet — matching the inline `// CATALOG TRACK:` comment.
  Contrast with the two functions immediately below it in the same file,
  `archiveRecipe` (1938-1951) and `restoreRecipe` (1953-1966), each of which
  DOES have `#if canImport(CloudKit) if let repo = recipeRepository { ...;
  return }` before its own Fly fallback — confirming the omission here is a
  gap against this file's own established pattern, not a deliberate
  "no guard needed" design.
- **Caller grep**: `grep -rn "fetchBaseIngredients"
  SimmerSmith/SimmerSmith/Features/` finds exactly three call sites of this
  `AppState` facade method (a fourth, `App/AppState+Ingredients.swift:14`'s
  `searchBaseIngredients`, is a separate façade over a different apiClient
  overload and already covered as its own row above):
  1. `Features/Recipes/RecipeEditorView.swift:685`, inside
     `searchIngredients(query:)` (lines 667-695, entirely read) —
     **guarded**: line 672, `guard !appState.isCloudKitOnly else {
     ingredientSuggestions = []; return }`, precedes the call by 13 lines,
     with an explicit comment (669-671) citing "SP-C review finding D:
     ingredient autocomplete resolves via the Fly catalog (no token → 401)
     in CloudKit-only mode. Skip the lookup." **This caller is correctly
     guarded and does NOT reach the call on a CloudKit household** — it is
     not part of this row's live-and-broken claim.
  2. `Features/Grocery/IngredientLinkPickerSheet.swift:178`, inside
     `private func search() async` (lines 171-183, entirely read):
     ```swift
     private func search() async {
         let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
         isSearching = true
         defer { isSearching = false }
         errorMessage = nil
         do {
             // SP-C: routed through AppState façade (closes the direct apiClient leak).
             results = try await appState.fetchBaseIngredients(query: trimmed, limit: 25)
         } catch {
             errorMessage = "Search failed: \(error.localizedDescription)"
             results = []
         }
     }
     ```
     No guard of any kind precedes the call — no CloudKit check, no
     `hasSavedConnection`/`isCloudKitOnly` check, no repository check, not
     even a minimum-length check on `trimmed`.
  3. `Features/Grocery/PantryItemEditorSheet.swift:252`, inside
     `private func runSearch(query: String) async` (lines 244-262, entirely
     read):
     ```swift
     private func runSearch(query: String) async {
         guard !query.isEmpty, query != lastSearchedQuery else { return }
         lastSearchedQuery = query
         isSearchingIngredients = true
         defer { isSearchingIngredients = false }
         do {
             // Route through the catalog façade in AppState (AppState+Recipes.swift)
             // so PantryItemEditorSheet does NOT reach into apiClient directly.
             let results = try await appState.fetchBaseIngredients(query: query, limit: 8)
             ...
         } catch {
             // Silent failure — autocomplete is a nice-to-have.
         }
     }
     ```
     The only guard is `!query.isEmpty, query != lastSearchedQuery` — a
     dedup/empty-string bail, not a household/backend-type check. Confirmed
     by grepping both files for `isCloudKitOnly\|hasSavedConnection`: zero
     matches in either `IngredientLinkPickerSheet.swift` or
     `PantryItemEditorSheet.swift` — neither sheet contains the guard
     anywhere, not just "not before the call."
- **Reachability — entry point 2, `IngredientLinkPickerSheet.search()`**
  (every hop read in full):
  1. `.task { if query.isEmpty { query = item.ingredientName; await search()
     } }` (`IngredientLinkPickerSheet.swift:139-144`) fires automatically
     the first time the sheet renders (`query` starts empty via
     `@State private var query = ""`), calling `search()` (site 2)
     unconditionally — no CloudKit/backend-type gate in the `.task` or
     anywhere else in the view's `body`.
  2. `IngredientLinkPickerSheet` is presented via
     `.sheet(isPresented: $showingLinker) { IngredientLinkPickerSheet(item:
     item) { ... } }` from three sites, each independently grepped:
     `Features/Grocery/GroceryFeedbackSheet.swift:135-144` (plain `.sheet`,
     no enclosing CloudKit guard; `showingLinker` set from an always-visible
     button inside the grocery-item-feedback form), `Features/Grocery/
     GroceryItemEditSheet.swift:104` (same pattern), and
     `Features/Recipes/RecipeSupport.swift:474` (same pattern). None of the
     three wraps the `.sheet` modifier or the triggering button in an
     `isCloudKitOnly`/`hasSavedConnection` conditional.
  3. Grocery item feedback/edit and recipe-side ingredient linking are
     ordinary, always-reachable features — `AppState+Grocery.swift` has
     full CloudKit repository plumbing (`groceryRepo`), confirming grocery
     is a first-class, shipped CloudKit-cutover surface, not a
     `ComingSoonView` placeholder.
- **Reachability — entry point 3, `PantryItemEditorSheet.runSearch()`**
  (every hop read in full):
  1. Typing in the "Name" `TextField` (`PantryItemEditorSheet.swift:161`)
     fires `.onChange` (line 151: `scheduleSearch(for: newValue)`), which
     debounces 300ms (`scheduleSearch`, lines 223-242) then calls
     `runSearch(query:)` (site 3) — no CloudKit/backend-type gate in either
     function.
  2. `PantryItemEditorSheet` is presented via `.sheet(item: $editorContext)
     { ctx in PantryItemEditorSheet(item: ctx.item) }`
     (`PantryView.swift:173-175`), triggered by the always-visible "+" /
     "Add pantry item" toolbar button (`PantryView.swift:155-164`, gated
     only on `pantryPrimary != .add`, a FAB-placement preference, not a
     household/backend-type check) or by tapping an existing pantry row
     (same `editorContext` binding).
  3. `PantryView` itself is the Pantry tab's root list (`.task { if
     appState.pantryItems.isEmpty { await appState.loadPantryItems() } }`,
     lines 176-179) — an ordinary, always-reachable tab, not behind
     `ComingSoonView`.
- **`isCloudKitOnly`/`hasSavedConnection` state confirmed applicable**: per
  the `createBaseIngredient` row above, `isCloudKitOnly` is a hardcoded
  `true` compile-time constant in the shipping build
  (`AppState.swift:280,294`: `private static let cloudKitOnlyBuild = true`),
  and `hasSavedConnection == false` (`AppState.swift:316-318`) is the
  default/typical state for a CloudKit-only household (no Fly server URL
  ever configured). `buildRequest`
  (`SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  2243-2253`) throws `SimmerSmithAPIError.missingServerURL` before any
  network attempt in that state, so both unguarded callers surface a
  caught, user-visible failure (`errorMessage = "Search failed: ..."` in
  `IngredientLinkPickerSheet`, a silent swallow in `PantryItemEditorSheet`
  — both dead ends, no CloudKit fallback path in either).
- **Verdict: CONFIRMED LIVE-AND-BROKEN, with one precision correction to
  the claimed evidence.** The claim's three-caller framing is right in
  substance but slightly imprecise about `RecipeEditorView.swift`: it
  correctly notes RecipeEditorView (line 685) DOES have the
  `!appState.isCloudKitOnly` guard and is therefore NOT part of the
  live-and-broken set — but the guard actually sits at line 672, thirteen
  lines *before* the call at 685, not "right before its call" as the claim
  phrases it; still functionally a correct read (nothing else intervenes
  between the guard and the call) so this is a wording nit, not a
  substantive error, and does not change the verdict. Of the two genuinely
  unguarded callers, both are independently confirmed reachable from
  ordinary, non-DEBUG user actions on a CloudKit household with zero
  `isCloudKitOnly`/`hasSavedConnection`/`#if canImport(CloudKit)` guard
  anywhere between the user action and the `apiClient.fetchBaseIngredients`
  call:
  - `Features/Grocery/IngredientLinkPickerSheet.swift:178` (`search()`),
    auto-triggered by `.task` (139-144) whenever the sheet appears —
    presented from `GroceryFeedbackSheet.swift:136`,
    `GroceryItemEditSheet.swift:104`, `RecipeSupport.swift:474`, exactly as
    claimed.
  - `Features/Grocery/PantryItemEditorSheet.swift:252` (`runSearch()`),
    triggered by typing a pantry item name (`scheduleSearch` ←
    `.onChange`), exactly as claimed.
  Matches the claimed user entry point. Confirmed LIVE-AND-BROKEN.

## Row: apiClient.createBaseIngredient (Features/Grocery/IngredientLinkPickerSheet.swift:192)

- **Distinct from the `AppState+Ingredients.swift:48` row above.** That row
  verified the `AppState` façade method's two callers
  (`IngredientsView.swift:593`, `RecipeEditorIngredientResolution.swift:571`)
  and only *noted* this call site in passing as "a third,
  previously-unfiled call site that bypasses the AppState facade entirely."
  This entry independently verifies that bypass call site as its own row,
  per the summary table's line `| createBaseIngredient |
  Features/Grocery/IngredientLinkPickerSheet.swift:192 | ... |`.
- **Call site**: `SimmerSmith/SimmerSmith/Features/Grocery/
  IngredientLinkPickerSheet.swift:192`, inside `createNew(named:)` (lines
  185-202, entire function read).
- **Full function body** (verbatim, no truncation):
  ```swift
  private func createNew(named trimmed: String) async {
      guard let weekID = appState.currentWeek?.weekId else { return }
      isCreatingNew = true
      defer { isCreatingNew = false }
      errorMessage = nil
      do {
          // 1. Create the new BaseIngredient as household_only.
          let created = try await appState.apiClient.createBaseIngredient(
              name: trimmed,
              submissionStatus: "household_only"
          )
          // 2. Link the grocery item to it (same path as tapping a
          // matching row).
          await link(to: created)
      } catch {
          errorMessage = "Couldn't add ingredient: \(error.localizedDescription)"
      }
  }
  ```
  The only early-return above the call is `guard let weekID =
  appState.currentWeek?.weekId else { return }` — this checks whether an
  active week exists, not CloudKit/repository/connection state; `weekID` is
  bound but never referenced again in the function (dead binding, doesn't
  change the guard's meaning). Confirmed by grepping the whole file
  (`grep -n "canImport(CloudKit)\|hasSavedConnection\|repositor"
  IngredientLinkPickerSheet.swift` → zero matches): no `#if
  canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check anywhere in this file, including in `search()`
  and `link(to:)` on either side of this function.
- **Caller grep — confirms genuinely unique call, not a duplicate of the
  façade row**: `grep -rn "appState.apiClient.createBaseIngredient"` across
  `SimmerSmith/SimmerSmith` returns exactly one hit, this line — a
  direct-bypass call (`appState.apiClient.createBaseIngredient(name:
  submissionStatus:)`, a 2-arg overload on `SimmerSmithAPIClient`) distinct
  from `appState.createBaseIngredient(name:normalizedName:category:...)`
  (the 13-arg `AppState` façade wrapper verified in the row above).
- **Reachability to a user action — three independent entry points, all
  read in full**:
  1. `Features/Grocery/GroceryFeedbackSheet.swift:53-58,135-144`: a plain
     `Button` ("Link to Ingredient" / "Re-link to Ingredient", always
     visible in the `Form`, no CloudKit/hasSavedConnection gate) sets
     `showingLinker = true`, wired to `.sheet(isPresented: $showingLinker)
     { IngredientLinkPickerSheet(item: item) { _ in dismiss() } }`.
     `GroceryFeedbackSheet` is presented from
     `Features/Grocery/GroceryView.swift:316-318` via `.sheet(item:
     $selectedItem) { GroceryFeedbackSheet(item: item) }`; `selectedItem`
     is set by a plain tap on a grocery row (`GroceryView.swift:225`,
     confirmed by grep). `GroceryView` is the Grocery tab body
     (`App/MainTabView.swift:37`, `.tag(AppState.MainTab.grocery)`).
  2. `Features/Grocery/GroceryItemEditSheet.swift:53-59,102-111`: same
     pattern — an always-visible "Link to Ingredient" `Button` sets
     `showingLinker = true`, wired to `.sheet(isPresented: $showingLinker)
     { IngredientLinkPickerSheet(item: item) { _ in dismiss() } }`.
     `GroceryItemEditSheet` is presented from `GroceryView.swift:320-322`
     via `.sheet(item: $editingItem) { GroceryItemEditSheet(item: item) }`,
     and `editingItem` is set by a plain `.onTapGesture { editingItem =
     item }` on a grocery row (`GroceryView.swift:219`, confirmed by grep).
     Same Grocery-tab reach as entry point 1.
  3. `Features/Recipes/RecipeSupport.swift:462-478,495-501`: an
     ingredient-review queue sheet wires `.sheet(item: $linkingItem) {
     IngredientLinkPickerSheet(item: item) { _ in Task { await
     refreshQueue() } } }`; `groceryItemsNeedingReview` filters
     `currentWeek?.groceryItems` for unresolved/flagged rows, no CloudKit
     gate on the filter or on setting `linkingItem`.
  In all three, once `IngredientLinkPickerSheet` is presented, typing a
  name with no search hits (or alongside partial matches) surfaces an
  always-enabled "Add \"<name>\" as new ingredient" `Button`
  (`IngredientLinkPickerSheet.swift:70-83,103-111`) that calls `Task {
  await createNew(named: trimmed) }` — no additional gate between the
  button and the function under audit.
- **`currentWeek` guard doesn't save this on a CloudKit household**:
  `currentWeek: WeekSnapshot?` (`App/AppState.swift:181`) is populated from
  either the Fly path or the CloudKit `weekRepository` path (multiple
  assignment sites across `AppState+Weeks.swift`/`AppState+Grocery.swift`/
  `AppState+Recipes.swift`); on any household with an active week — the
  normal, non-empty state the whole Grocery/Recipes flow assumes — the
  guard passes regardless of `hasSavedConnection` or repository state, so
  it gates nothing relevant to this claim.
- **Confirmed genuinely broken, not just theoretically reachable**: same
  underlying `apiClient.createBaseIngredient` implementation as the row
  above — `SimmerSmithAPIClient.swift:2251-2252` (`buildRequest`) throws
  `SimmerSmithAPIError.missingServerURL` before any network call when
  `baseURLString.isEmpty`, i.e. whenever `hasSavedConnection == false`.
  `createNew(named:)`'s `catch` (lines 199-201) surfaces this as
  `errorMessage = "Couldn't add ingredient: \(error.localizedDescription)"`
  — a visible save failure, not a silent no-op, and no CloudKit fallback
  path exists anywhere in this file for the create-new-ingredient flow.
- **Verdict: CONFIRMED LIVE-AND-BROKEN.** On a CloudKit household
  (repositories non-nil, `hasSavedConnection == false`), all three claimed
  entry points — grocery-row feedback sheet, grocery-row edit sheet, and
  the recipe ingredient-review queue — reach `IngredientLinkPickerSheet`'s
  "Add as new ingredient" button with zero CloudKit/hasSavedConnection/
  repository gate anywhere in the chain, which calls `createNew(named:)`,
  whose only guard (`currentWeek?.weekId`) is unrelated to backend
  selection, which calls `appState.apiClient.createBaseIngredient`
  directly (bypassing the already-broken `AppState` façade entirely),
  which throws `missingServerURL` against the dead Fly backend.

## Row: apiClient.submitIngredientForAdoption (IngredientsView.swift:564, submitForAdoption)

- **Call site**: `SimmerSmith/SimmerSmith/Features/Ingredients/IngredientsView.swift:559-572`,
  inside `BaseIngredientEditorSheet.submitForAdoption(_:)` (entire function
  read).
- **Full function body** (verbatim, no truncation):
  ```swift
  private func submitForAdoption(_ ingredient: BaseIngredient) async {
      isSaving = true
      defer { isSaving = false }
      errorMessage = nil
      do {
          _ = try await appState.apiClient.submitIngredientForAdoption(
              baseIngredientID: ingredient.baseIngredientId
          )
          // Bounce so the user reopens on the now-submitted row.
          dismiss()
      } catch {
          errorMessage = error.localizedDescription
      }
  }
  ```
  No `#if canImport(CloudKit)` block, no repository-nil guard, no
  `hasSavedConnection` check anywhere in the function — and unlike most
  other rows in this file, this call bypasses the `AppState` facade
  entirely, going straight at `appState.apiClient.` (confirmed via
  `grep -n "hasSavedConnection\|canImport(CloudKit)\|repositories"
  IngredientsView.swift` → zero matches in the whole file).
- **Callee confirmed real, not a stub**:
  `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  1278-1284` issues an actual `POST /api/ingredients/{id}/submit` via the
  shared private `request(...)` helper.
- **Button visibility guard is data-only, not backend-type**: the button
  lives in `submissionSection(for:)` (lines 515-547), gated only by
  `if ingredient.submissionStatus == "household_only"` (line 522) —
  `submissionStatus` is a plain string field on `BaseIngredient`, unrelated
  to `hasSavedConnection`/CloudKit/repository state.
- **Caller/entry-point grep and correction to the claimed evidence**:
  `submissionSection(for:)` is only invoked from `BaseIngredientEditorSheet.body`
  at line 478-480: `if let existing = context.ingredient {
  submissionSection(for: existing) }` — i.e. it renders ONLY when the sheet
  is editing an *existing* ingredient, never when creating a new one.
  - **`IngredientsView.swift:62` — REFUTED as a path to this button.** That
    `.sheet(item: $editorContext)` is wired to the toolbar "New Ingredient"
    button (lines 51-58), which sets `editorContext =
    BaseIngredientEditorContext()` — `BaseIngredientEditorContext.init`
    (lines 414-421) defaults `ingredient` to `nil`. With `context.ingredient
    == nil`, line 478's `if let existing` never enters, so
    `submissionSection`/the "Submit for global adoption" button never
    renders on this path. The claim's citation of line 62 as a reachable
    entry point to this specific button is wrong.
  - **`IngredientsView.swift:166` — CONFIRMED reachable, and the only real
    path.** That `.sheet(item: $editorContext)` lives in `IngredientDetailView.body`
    and is set at line 133 by the toolbar `Menu("Manage")`'s "Edit" button
    (lines 128-134): `editorContext = BaseIngredientEditorContext(ingredient:
    detail.ingredient)` — here `context.ingredient` is non-nil, so line
    478's branch fires and `submissionSection` renders, showing the button
    whenever `detail.ingredient.submissionStatus == "household_only"`.
- **Full reachability chain to `IngredientsView.swift:166`** (every hop read
  in full):
  1. `IngredientDetailView` is pushed via a plain `NavigationLink`
     (`IngredientCatalogList.swift:26-27`) on every row of
     `ForEach(ingredients)` — no CloudKit/`hasSavedConnection` guard.
  2. `IngredientCatalogList` is embedded directly in `IngredientsView.body`
     (`IngredientsView.swift:36-40`), a flat `List`, no wrapping guard.
  3. `IngredientsView` is reached via `Features/Settings/SettingsView.swift:
     479-483`: `NavigationLink { IngredientsView() } label: { Label("Manage
     Ingredient Catalog", ...) }` — confirmed a plain, unconditional sibling
     `Section` inside the flat top-level `Form` (`SettingsView.body`, lines
     33-484 scanned for every `Section`/`if`/`ForgeSection`/`GrocerySection`
     between lines 84-485: the only `#if canImport(CloudKit)` in that
     stretch, lines 65-79, wraps an unrelated `SyncStatusDetailView` link
     inside the *first* Section and closes long before line 475's Section
     opens; the only `if` guarding a *Section* is line 357
     (`MonetizationFlags.paywallEnabled || appState.isPro`), which wraps a
     different Section at 358 and is closed before the ingredient-catalog
     Section begins; the nearest `hasSavedConnection` check in the file is
     an unrelated Section starting at line 629).
  4. Full chain: Settings → "Manage Ingredient Catalog" → tap any ingredient
     row → "Manage" menu → "Edit" → (if `submissionStatus ==
     "household_only"`) "Submit for global adoption" → `submitForAdoption(_:)`
     → `appState.apiClient.submitIngredientForAdoption(...)`.
- **Confirmed genuinely broken, not just theoretically reachable**:
  `hasSavedConnection` (`AppState.swift:316-318`) is
  `!ConnectionSettingsStore.normalizeServerURL(serverURLDraft).isEmpty` —
  `false` means no Fly server URL configured. `buildRequest`
  (`SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:
  2243-2253`) throws `SimmerSmithAPIError.missingServerURL` before any
  network attempt in exactly that state, caught by `submitForAdoption`'s own
  `catch { errorMessage = error.localizedDescription }` (line 569-571) — the
  user taps the button, sees a save-failure banner, and the ingredient is
  never actually submitted. No CloudKit fallback exists anywhere in this
  chain.
- **Verdict: CONFIRMED LIVE-AND-BROKEN, with one correction to the claimed
  entry-point list.** `IngredientsView.swift:62` (the "New Ingredient" sheet)
  does NOT reach this button — `context.ingredient` is `nil` there, so
  `submissionSection` never renders. `IngredientsView.swift:166` (the "Edit"
  sheet reached from `IngredientDetailView`'s "Manage" menu) DOES reach it:
  every hop from Settings → Manage Ingredient Catalog → an ingredient row →
  Manage → Edit → Submit for global adoption was read in full and none
  contains a repository-nil check, `hasSavedConnection` check, or `#if
  canImport(CloudKit)` branch. The underlying call is a genuine facade-bypass
  (`appState.apiClient.` direct, not `appState.`) already flagged as a
  precedent-setting gap in this file's `createBaseIngredient` row ("same
  file already being flagged in `simmersmith-990.5.1`'s notes for a sibling
  facade-bypass"). On a CloudKit household (repositories non-nil,
  `hasSavedConnection == false`), the single corrected entry point is a
  concrete, reachable path from an ordinary non-DEBUG user action to the
  claimed line.
