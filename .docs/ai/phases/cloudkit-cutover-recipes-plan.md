# CloudKit Cutover — Slice 1: Recipes + Data-Layer Skeleton — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> **Spec:** `.docs/ai/phases/cloudkit-cutover-recipes-spec.md` (read it first). This plan implements slice 1.

**Goal:** Back the app's Recipes feature with the CloudKit household plane instead of Fly, and stand up the reusable `HouseholdSession` + repository + mapper skeleton every later feature inherits.

**Architecture:** A long-lived `HouseholdSession` owns the household `CKSyncEngine` stack + local store and emits a change-signal on sync. A `RecipeRepository` reads/writes recipes through that store (offline-first), mapping `RecipeSummary ⇄ HouseholdRecordValue (+ child records + CKAsset image)` via a pure `RecipeRecordMapper`. AppState stays the view-facing façade — its recipe data methods delegate to the repo; views + domain structs are untouched.

**Tech Stack:** Swift 6 / SwiftUI, CloudKit (`CKSyncEngine`), the `SimmerSmithCloudKit` SwiftPM package (already built + on-device-verified), Swift Testing for headless tests, `xcodebuild` for device archives.

## Global Constraints

- **Custom CKSyncEngine stack for the household plane — never NSPCKC** (Spike-1: blanket LWW corrupts the grocery field-merge). NSPCKC is the private plane only.
- **AppState stays the façade.** Do NOT change the SwiftUI views or the `RecipeSummary`/`RecipeIngredient`/`RecipeStep` domain structs (`SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift`). Only AppState method *bodies* change.
- **The manifest is the schema authority.** Field/ref names + types come from `HouseholdRecordType.recipe/.recipeIngredient/.recipeStep` (`SimmerSmithCloudKit/Sources/HouseholdRecords/HouseholdRecordType.swift`). Never invent a field name — derive it from the manifest.
- **Derived fields are never fabricated** (spec §5-F): `daysSinceLastUsed`, `familyDaysSinceLastUsed`, `isVariant`, `variantCount`, `sourceRecipeCount`, `overrideFields`, `nutritionSummary`, `familyLastUsed` are NOT persisted — recompute from the store or set to nil/0. The detail view must show empty, not a guess.
- **AI-dependent recipe methods are OUT of this slice** (import/variation/suggestion/refine/nutrition-estimate/AI-image). Leave them calling Fly during the transition BUT guarded so they fail gracefully (not a hard crash) — they get rewired to `AIProviderKit` in the AI track before SP-D.
- **Pure code is headless-tested** (`swift test` in `SimmerSmithCloudKit`, no iCloud account). CloudKit-touching integration is verified **on-device via TestFlight** (the proven path; the sim/CI cannot run signed CloudKit). A task whose deliverable is CloudKit-integration ends with an on-device check button + a manual `[?] awaiting on-device verify` mark, per AGENTS.md phase-loop rules.
- **One commit per task.** Don't push. New CloudKit record types require the dashboard "Deploy to Production" step. This slice adds ONE: `ManagedListItem` (Task 4b) — Taylor must run the dashboard deploy + the cktool schema validate before the on-device metadata check passes. The recipe types are already deployed.
- **Metadata source (decided):** recipe metadata (cuisines/tags/units) is a **household record type** (`ManagedListItem`), NOT the PUBLIC catalog — because it's user-extensible (`createManagedListItem`) and clients cannot write the curator-only PUBLIC catalog. Each household owns its set (built-in defaults seeded from Fly on migration + user-added).

---

## File Structure

| File | New? | Responsibility |
|---|---|---|
| `SimmerSmithKit/Sources/SimmerSmithKit/CloudKit/RecipeRecordMapper.swift` | new | Pure `RecipeSummary ⇄ records (+image-presence)`, both directions. Headless-testable. |
| `SimmerSmithCloudKit/Tests/.../RecipeRecordMapperTests.swift` | new | Round-trip + field-classification + child-diff + tags-serialization tests. |
| `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdSyncEngine.swift` | modify | Add a `onStoreChanged` hook fired from `handleEvent` when sync mutates the store. |
| `SimmerSmith/SimmerSmith/App/HouseholdSession.swift` | new | Owns + boots the 3 planes; exposes `SyncPhase` + the change-signal; provisions the zone. |
| `SimmerSmith/SimmerSmith/Data/RecipeRepository.swift` | new | Recipe CRUD + image over the household store; holds the `@Observable` recipe projection. |
| `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift` | modify | Delegate IN-scope methods to `RecipeRepository`; guard OUT-scope AI methods. |
| `SimmerSmith/SimmerSmith/App/AppState.swift` | modify | Hold the `HouseholdSession` + `RecipeRepository`; add `fetchBaseIngredients` façade wrapper. |
| `SimmerSmith/.../Features/Settings/CloudKitDebugView.swift` | modify | Add a "Recipes repo round-trip" on-device check button. |

**Task order (each independently testable):**
1. `RecipeRecordMapper` (pure, full TDD) → 2. engine `onStoreChanged` hook → 3. `HouseholdSession` → 4. `RecipeRepository` → 5. AppState+Recipes rewire + `fetchBaseIngredients` façade → 6. first-launch recipe migration → 7. on-device verification button + run.

---

### Task 1: `RecipeRecordMapper` (pure domain↔record mapping)

The load-bearing new logic, and the only fully headless-testable piece. Put it in `SimmerSmithKit` (it imports `SimmerSmithCloudKit`'s `HouseholdRecords` for the value types, and the app + tests both use it).

**Files:**
- Create: `SimmerSmithKit/Sources/SimmerSmithKit/CloudKit/RecipeRecordMapper.swift`
- Test: `SimmerSmithCloudKit/Tests/HouseholdRecordsTests/RecipeRecordMapperTests.swift` (co-located with the manifest tests so it shares the `HouseholdRecords` import; if `SimmerSmithKit` can't depend on the package in tests, put the test in a new `SimmerSmithKit` test target — confirm the dependency direction before writing).

**Interfaces:**
- Consumes: `HouseholdRecordValue`, `ScalarValue`, `HouseholdRecordType` (from `HouseholdRecords`); `RecipeSummary`, `RecipeIngredient`, `RecipeStep` (from `SimmerSmithKit`).
- Produces:
  - `enum RecipeRecordMapper`
  - `static func records(from recipe: RecipeSummary) -> (recipe: HouseholdRecordValue, ingredients: [HouseholdRecordValue], steps: [HouseholdRecordValue])`
  - `static func recipe(from rec: HouseholdRecordValue, ingredients: [HouseholdRecordValue], steps: [HouseholdRecordValue], hasImage: Bool) -> RecipeSummary`
  - `static func encodeTags(_ tags: [String]) -> String` / `static func decodeTags(_ s: String) -> [String]`

- [ ] **Step 1: Verify the two field inventories before writing a line.** Read `HouseholdRecordType.recipe/.recipeIngredient/.recipeStep` (`.fields` + `.refs`) and the `RecipeSummary`/`RecipeIngredient`/`RecipeStep` structs (`SimmerSmithModels.swift:1750/730/813`). Confirm the spec §5 A/B/C/D/F classification against the actual code. Note any field present in one but not the other.

- [ ] **Step 2: Pin the `tags` serialization.** Grep the backend for how `recipes.tags` (Text column) is serialized on save/read (`app/` recipe save handler + `migrateGroceryItem`/the recipe migrate transform reads `tags` verbatim as a string). The mapper's `encodeTags`/`decodeTags` MUST produce the same string format migrated recipes have, or migrated + newly-saved recipes will disagree. Record the format here in a comment before coding.

- [ ] **Step 3: Write the failing round-trip test** (`swift test` target). Build a `RecipeSummary` with every Category-A/B/C/D field populated (2 ingredients, 2 steps incl. a substep, tags `["quick","veg"]`, a `baseRecipeId`, a `recipeTemplateId`), map to records and back, and assert the A/B/C/D fields survive and the derived (F) fields are nil/0/recomputed — not echoed:

```swift
@Test func recipeRoundTripsThroughRecords() {
    let r = RecipeSummary(recipeId: "R1", recipeTemplateId: "TPL", baseRecipeId: "R0",
        name: "Tacos", mealType: "dinner", cuisine: "mexican", servings: 4,
        prepMinutes: 15, cookMinutes: 20, tags: ["quick", "veg"], instructionsSummary: "stuff",
        favorite: true, archived: false, source: "manual", sourceLabel: "", sourceUrl: "",
        notes: "n", memories: "m", lastUsed: Date(timeIntervalSince1970: 1_700_000_000),
        kidFriendly: true, difficultyScore: 2, iconKey: "taco",
        ingredients: [RecipeIngredient(ingredientId: "I1", ingredientName: "Tomato", quantity: 2, unit: "cup"),
                      RecipeIngredient(ingredientId: "I2", ingredientName: "Onion")],
        steps: [RecipeStep(stepId: "S1", sortOrder: 0, instruction: "chop"),
                RecipeStep(stepId: "S2", sortOrder: 1, instruction: "cook")])
    let recs = RecipeRecordMapper.records(from: r)
    let back = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: recs.ingredients, steps: recs.steps, hasImage: false)
    #expect(back.recipeId == "R1" && back.name == "Tacos" && back.cuisine == "mexican")
    #expect(back.servings == 4 && back.favorite == true && back.kidFriendly == true)
    #expect(back.tags == ["quick", "veg"])                 // serialization round-trips
    #expect(back.baseRecipeId == "R0" && back.recipeTemplateId == "TPL")
    #expect(back.ingredients.map(\.ingredientName) == ["Tomato", "Onion"])
    #expect(back.steps.map(\.instruction) == ["chop", "cook"])
    #expect(back.nutritionSummary == nil && back.variantCount == 0)   // derived NOT fabricated
}
```
> NOTE: adjust the `RecipeSummary`/`RecipeIngredient`/`RecipeStep` initializer arguments in this test to the REAL initializers you confirmed in Step 1 — the struct has many fields; use the real init or memberwise defaults. Do not invent argument labels.

- [ ] **Step 4: Run it, verify it fails** — `swift test --package-path SimmerSmithCloudKit --filter recipeRoundTrips` → FAIL (`RecipeRecordMapper` undefined).

- [ ] **Step 5: Implement `RecipeRecordMapper`.** Mirror the field classification from §5. For `records(from:)`: build `HouseholdRecordValue(type: .recipe, recordName: recipe.recipeId, scalars: [...], refs: [...])` setting only Category-A/B/C scalars + the `baseRecipe`/`recipeTemplateID` refs (omit nil/empty, matching `migrateHouseholdRecord`'s defensive omission); build one `.recipeIngredient` value per ingredient (recordName = `ingredientId` or a deterministic fallback) with the `recipe` ref = recipe.recipeId; same for steps (+ `parentStep` for substeps). For `recipe(from:)`: read scalars back via the manifest field names, `decodeTags`, set derived fields to nil/0. Write `encodeTags`/`decodeTags` to the format pinned in Step 2.
> Use `migrateHouseholdRecord` (`HouseholdRecordMigration.swift`) as the reference for field-name derivation + defensive coercion — the mapper is its inverse for the live path. Mirror it; don't re-derive the snake_case rules.

- [ ] **Step 6: Run, verify pass** — same filter → PASS.

- [ ] **Step 7: Add edge-case tests + make them pass** — empty tags (`encodeTags([]) `↔`decodeTags` = `[]`), a recipe with no ingredients/steps, a substep under a step (round-trips the `parentStep` ref), and a minimal recipe (only `recipeId`+`name`). Run → PASS.

- [ ] **Step 8: Commit** — `git add` the mapper + test; `git commit -m "feat(sp-c): RecipeRecordMapper — RecipeSummary<->CloudKit records (pure, headless-tested)"`.

---

### Task 2: `HouseholdSyncEngine.onStoreChanged` hook

The repository needs to know when sync mutates the local store (remote edits) so it can refresh. Add a callback the session sets; fire it from the delegate after the store changes.

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdSyncEngine.swift`

**Interfaces:**
- Produces: `public var onStoreChanged: (@Sendable () -> Void)?` on `HouseholdSyncEngine`, invoked after `fetchedRecordZoneChanges` / `sentRecordZoneChanges` mutate `store`.

- [ ] **Step 1: Read `handleEvent` first.** Open `HouseholdSyncEngine.swift` and locate every place `store.setRecord`/`applyRemoteModification`/`removeRecord` is called inside `handleEvent` (the `fetchedRecordZoneChanges` + `sentRecordZoneChanges` cases). The hook fires once per event after those mutations — do NOT fire per-record (debounce to per-event).

- [ ] **Step 2: Add the property** — `public var onStoreChanged: (@Sendable () -> Void)?` near the other public engine config (the `merger` seam). Swift-5-mode target, so a plain optional closure is fine.

- [ ] **Step 3: Fire it** at the end of the `fetchedRecordZoneChanges` case (after the modification/deletion loops) and after `sentRecordZoneChanges` applies server-record changes. Call `onStoreChanged?()`.

- [ ] **Step 4: Verify it builds + nothing regresses** — `swift test --package-path SimmerSmithCloudKit` → all existing tests still pass (the hook is nil in tests, so behavior is unchanged). Expected: the prior green count (102) unchanged.

- [ ] **Step 5: Commit** — `git commit -m "feat(sp-c): HouseholdSyncEngine.onStoreChanged hook for repository refresh"`.

---

### Task 3: `HouseholdSession` (boots + owns the planes)

**Files:**
- Create: `SimmerSmith/SimmerSmith/App/HouseholdSession.swift`

**Interfaces:**
- Consumes: `HouseholdSyncEngine`, `HouseholdLocalStore`, `HouseholdZoneProvisioner`, `DispatchingMerger`+the three mergers, `PublicCatalogReader` (all from the package); `makeSimmerSmithPrivatePlaneContainer` (SimmerSmithKit).
- Produces:
  - `@MainActor @Observable final class HouseholdSession`
  - `let store: HouseholdLocalStore`, `let engine: HouseholdSyncEngine`, `let catalog: PublicCatalogReader`, `let zoneID: CKRecordZone.ID`
  - `var syncPhase: SyncPhase`
  - `func start() async` — provision zone if needed, set the merger, set `engine.onStoreChanged` to bump a `storeRevision: Int` (so `@Observable` consumers refresh), `fetchChanges()`, set `syncPhase`.

- [ ] **Step 1: Read the construction pattern to mirror.** Open `CloudKitDebugView.runHouseholdSyncCheck` (and `runMigrationCheck`) and copy EXACTLY how it builds `HouseholdSyncEngine(database:zoneID:store:stateURL:)`, sets `engine.merger = DispatchingMerger([...])`, and drives `fetchChanges()`. The session is the same construction with app lifetime + a real `stateURL` in Application Support (not a temp file). Use the real container `iCloud.app.simmersmith.cloud`, `.privateCloudDatabase`, and the household zone name (decide the zone name: the production household zone — confirm what `HouseholdZoneProvisioner` uses; do NOT reuse a `*-test` zone name).

- [ ] **Step 2: Write `HouseholdSession`** as `@MainActor @Observable`. `start()`: ensure the zone (provisioner), construct store+engine+merger, set `engine.onStoreChanged = { [weak self] in Task { @MainActor in self?.storeRevision += 1 } }`, `try await engine.fetchChanges()`, set `syncPhase = .synced(Date())`; on throw set `.offline`/`.failed`. Persist the engine state to a stable `stateURL` (Application Support) so sync tokens survive launches.
> Codebase-derived: do not fabricate the provisioner/engine init args — read their signatures (`HouseholdZoneProvisioner`, `HouseholdSyncEngine.init`) and use them verbatim. The `SyncPhase` enum already exists in AppState — reuse it, don't redefine.

- [ ] **Step 3: Build the app** (Debug, sim) — `xcodebuild -scheme SimmerSmith -configuration Debug -destination 'platform=iOS Simulator,id=<sim>' build` → BUILD SUCCEEDED. (No unit test — this is account/CloudKit integration, verified on-device in Task 7.)

- [ ] **Step 4: Commit** — `git commit -m "feat(sp-c): HouseholdSession — long-lived owner of the CloudKit planes"`.

---

### Task 4: `RecipeRepository`

**Files:**
- Create: `SimmerSmith/SimmerSmith/Data/RecipeRepository.swift`

**Interfaces:**
- Consumes: `HouseholdSession` (store + engine), `RecipeRecordMapper`, `RecipeImageCodec`, `HouseholdRecordCodec`.
- Produces:
  - `@MainActor @Observable final class RecipeRepository`
  - `private(set) var recipes: [RecipeSummary]` (the projection AppState exposes)
  - `func reload()` — recompute `recipes` from `session.store` (decode `.recipe` records + their `.recipeIngredient`/`.recipeStep` children via the mapper; compute derived fields: `variantCount`/`isVariant` from the `baseRecipe` ref graph, `daysSinceLastUsed` from `lastUsed`).
  - `func save(_ draft: RecipeDraft) -> RecipeSummary` (build a `RecipeSummary`, map → records, diff children vs store, `engine.save` changed + `engine.delete` removed, `reload()`, return).
  - `func setFavorite(_ recipeId: String, _ on: Bool)`, `func archive/restore(_ recipeId:)`, `func delete(_ recipeId:)` (→ `engine.deleteCascading`).
  - image: `func imageBytes(_ recipeId:) async -> Data?`, `func setImage(_ recipeId:, _ data: Data, mime: String)`, `func removeImage(_ recipeId:)` via `RecipeImageCodec`.

- [ ] **Step 1: Read the store/engine + RecipeImageCodec APIs** — `HouseholdLocalStore` (`records(ofType:)`, `record(for:)`, `allRecords`), `HouseholdSyncEngine` (`save`/`delete`/`deleteCascading`/`sendUntilDrained`), `RecipeImageCodec` (encode/decode, the `rimg:<id>` recordName, the assetNotDownloaded distinction). Mirror `EventMergeAdapter`'s upsert idiom (`if let existing = store.record(for:id) { encode-into; save } else { save(makeRecord) }`) for the recipe records.

- [ ] **Step 2: Implement `reload()`** — gather `.recipe` records, for each gather its `.recipeIngredient`/`.recipeStep` children (filter by the `recipe` ref), `RecipeRecordMapper.recipe(from:...)`, compute derived fields from the in-memory set, sort to match the old list order (by name/updatedAt — match `AppState+Recipes`' current ordering). Subscribe to `session.storeRevision` (observe it) so `reload()` runs on sync.

- [ ] **Step 3: Implement the writes** using the mapper + the upsert idiom + child diff (save changed children, delete removed). `save` returns the reloaded `RecipeSummary`. Wire `engine.sendUntilDrained()` in a background `Task` after writes so edits push (mirror how the DEBUG checks drain).

- [ ] **Step 4: Build (Debug, sim)** → BUILD SUCCEEDED. (Logic that's pure-enough — the child-diff — can get a small headless test against an in-memory `HouseholdLocalStore`, which constructs without an account; add one if practical. The engine save/sync is on-device-verified.)

- [ ] **Step 5: Commit** — `git commit -m "feat(sp-c): RecipeRepository — recipe CRUD + image over the household store"`.

---

### Task 4b: Recipe metadata via a `ManagedListItem` household record type

The editor's cuisine/tag/unit dropdowns are user-extensible reference data → a household record type (decided above). Adding a manifest type, so it follows the established SP-A pattern (manifest case → codec/migrate for free → CKDSL → deploy).

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/HouseholdRecords/HouseholdRecordType.swift` (add `.managedListItem`)
- Modify: `.docs/ai/phases/phase0-schema.ckdb` (append the `ManagedListItem` RECORD TYPE block)
- Modify/Create: `SimmerSmith/SimmerSmith/Data/RecipeRepository.swift` (or a `MetadataRepository`) — read `ManagedListItem` → `RecipeMetadata`; `createManagedListItem`.
- Test: `SimmerSmithCloudKit/Tests/HouseholdRecordsTests/...` (manifest classification + migrate of `.managedListItem`)

**Interfaces:**
- Produces: `HouseholdRecordType.managedListItem`; `migrateHouseholdRecord(.managedListItem, row)`; repo `func reloadMetadata()` → `RecipeMetadata`, `func createManagedListItem(kind: String, name: String) -> ManagedListItem`.

- [ ] **Step 1: Verify the backend model + payload first.** Read `app/models/` for the `ManagedListItem` (or managed-list) model — its exact columns (kind, name, sort_order, built_in?, timestamps) + how `/api/recipes/metadata` shapes cuisines/tags/units. Map the columns the same way the other manifest types do (snake_case). Confirm `RecipeMetadata` + `ManagedListItem` Swift struct shapes in `SimmerSmithModels.swift`.

- [ ] **Step 2: Add `.managedListItem` to the manifest** — recordTypeName `"ManagedListItem"`, recordName policy (`.det` keyed by `kind`+`name` to collapse dup creates, OR `.pk` by id — pick per the backend PK; if there's a surrogate id use `.pk`), fields (`kind` queryable, `name`, `sortOrder` int, `builtIn` bool if present, `createdAt`, `updatedAt`), no refs. Follow the exact style of the neighboring cases.

- [ ] **Step 3: Write the failing manifest test** (mirror `HouseholdRecordMigrationTests`): `migrateHouseholdRecord(.managedListItem, ["id":"M1","kind":"cuisine","name":"Italian","sort_order":NSNumber(value:2)])` → recordName + scalars correct. Run `swift test --filter managedListItem` → FAIL.

- [ ] **Step 4: Run → PASS** after the manifest case lands (codec + migrate are manifest-driven, so no new transform code). Confirm the `weekTypesLanded`-style count test if one asserts the total type count — update it (now N+1 types).

- [ ] **Step 5: Generate + append the CKDSL** for `ManagedListItem` (use the `HouseholdRecordType.managedListItem.ckdsl()` emit trick from the SP-A week-types work), insert into `phase0-schema.ckdb`, and `xcrun cktool validate-schema ... --environment development` → "Schema is valid."

- [ ] **Step 6: Repository + AppState delegate** — `reloadMetadata()` reads `ManagedListItem` records, groups by `kind` into `RecipeMetadata`; `createManagedListItem` writes a record via the engine. Repoint `AppState.refreshRecipeMetadata` + `createManagedListItem` to delegate (keep signatures). Build (Debug, sim) → SUCCEEDED.

- [ ] **Step 7: Commit** — `git commit -m "feat(sp-c): ManagedListItem household type + recipe-metadata repository"`. **Then Taylor: cktool validate + CloudKit Dashboard 'Deploy to Production' for ManagedListItem before the on-device metadata check.**

---

### Task 5: AppState+Recipes rewire + `fetchBaseIngredients` façade

**Files:**
- Modify: `SimmerSmith/SimmerSmith/App/AppState.swift` (hold `HouseholdSession` + `RecipeRepository`; add the façade wrapper)
- Modify: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift` (delegate IN-scope methods; guard OUT-scope)

**Interfaces:**
- Consumes: `RecipeRepository`, `HouseholdSession`, `PublicCatalogReader`.
- Produces (unchanged signatures — only bodies change): `refreshRecipes`, `fetchRecipe`, `saveRecipe`, `archiveRecipe`, `restoreRecipe`, `deleteRecipe`, the image methods; plus a NEW `func fetchBaseIngredients(query: String, limit: Int) async throws -> [BaseIngredientSummary]` façade.

- [ ] **Step 1: Confirm the exact method signatures** in `AppState+Recipes.swift` (return types, the `RecipeDraft`/`RecipeSummary` shapes) and the `recipes` property the views bind to. The rewrite MUST preserve every signature + keep `appState.recipes` populated (point it at `recipeRepository.recipes`, or mirror it on each `reload`).

- [ ] **Step 2: Wire the repo into AppState** — construct `HouseholdSession` + `RecipeRepository` in AppState init (or lazily after iCloud sign-in); call `session.start()` at launch. Make `var recipes: [RecipeSummary]` return `recipeRepository.recipes` (or observe + mirror).

- [ ] **Step 3: Rewire the IN-scope methods** to delegate: `refreshRecipes` → `recipeRepository.reload()` (the store is already synced; reload is local); `saveRecipe` → `recipeRepository.save`; archive/restore/delete/favorite → the repo; image methods → the repo. Remove their HTTP bodies.

- [ ] **Step 4: Guard the OUT-scope AI methods** — `importRecipeDraft`/`searchRecipeOnWeb`/`generateRecipeVariationDraft`/`generateRecipeSuggestionDraft`/`refineRecipeDraft`/`estimateRecipeNutrition`/AI-image. Per the spec §4: keep them calling Fly for now, but wrap so a Fly failure surfaces a clear "AI not available in this build yet" message instead of crashing. Add a `// AI TRACK: rewire to AIProviderKit` marker on each.

- [ ] **Step 5: Add the `fetchBaseIngredients` façade** and repoint `RecipeEditorView:~670` from `appState.apiClient.fetchBaseIngredients(...)` to `appState.fetchBaseIngredients(...)`. The façade resolves against `session.catalog` (`PublicCatalogReader`) + the household zone per §8.2. Grep `Features/` for any OTHER direct `apiClient.` recipe calls and route them through the façade too.

- [ ] **Step 6: Build (Debug, sim)** → BUILD SUCCEEDED, no view changes required.

- [ ] **Step 7: Commit** — `git commit -m "feat(sp-c): AppState+Recipes delegates to RecipeRepository; close apiClient façade leak"`.

---

### Task 6: First-launch recipe migration

**Files:**
- Create: `SimmerSmith/SimmerSmith/Data/RecipeMigrationLoader.swift`
- Modify: `AppState`/`HouseholdSession` to invoke it once when the recipe scope's `MigrationReceipt` is absent.

**Interfaces:**
- Consumes: the existing Fly `apiClient` (recipes GET), `HouseholdMigrationRunner`, `migrateHouseholdRecord`, `RecipeImageCodec`.
- Produces: `func migrateRecipesIfNeeded() async` — pulls `/api/recipes?include_archived=true` (+ per-recipe detail for ingredients/steps if the list omits them), shapes rows into `HouseholdMigrationRunner.Export.householdRecords[.recipe/.recipeIngredient/.recipeStep]`, runs the runner (idempotent, receipt-gated), pulls each recipe's image bytes → `RecipeImageCodec`.

- [ ] **Step 1: Confirm the recipes GET payload shape** — what `/api/recipes` returns (does the list include ingredients/steps, or only summaries needing a per-recipe GET?). Shape the export rows to the **Postgres column names** `migrateHouseholdRecord` expects (snake_case), NOT the Swift struct names — the runner's transform reads DB-row keys.

- [ ] **Step 2: Implement `migrateRecipesIfNeeded`** — gate on `engine.store.record(for: receiptID(scope:"recipes"))` absent; build the Export INCLUDING `householdRecords[.managedListItem]` from `GET /api/recipes/metadata` (seed the user's cuisines/tags/units, Task 4b) alongside `.recipe/.recipeIngredient/.recipeStep`; `HouseholdMigrationRunner(engine:zoneID:).migrate(scope:"recipes", export:)`; for each recipe with an image, GET its bytes + `RecipeImageCodec` save; `engine.sendUntilDrained()`. Idempotent by the receipt — safe to call every launch.

- [ ] **Step 3: Invoke it** after `session.start()` on launch (once iCloud + the zone are ready), before the first `reload()`.

- [ ] **Step 4: Build (Debug, sim)** → BUILD SUCCEEDED.

- [ ] **Step 5: Commit** — `git commit -m "feat(sp-c): one-time first-launch recipe migration Fly->CloudKit"`.

---

### Task 7: On-device verification (TestFlight) + a debug round-trip button

CloudKit integration can only be truly verified on a signed device against Production CloudKit.

**Files:**
- Modify: `SimmerSmith/.../Features/Settings/CloudKitDebugView.swift` (add a "Recipes repo round-trip" button)

- [ ] **Step 1: Add a debug check** `runRecipeRepoCheck()` (mirror `runMigrationCheck`'s structure): construct a `RecipeRepository` over a fresh test zone, `save` a recipe via the mapper, assert a 2nd engine sees it with fields intact + the image round-trips, then `delete` (cascading) + assert gone. Add the button to the panel.

- [ ] **Step 2: Headless first** — `swift test --package-path SimmerSmithCloudKit` green; app `xcodebuild` Debug build green.

- [ ] **Step 3: Cut a TestFlight build** — bump `CURRENT_PROJECT_VERSION`, `bash scripts/release-ios.sh`, confirm `EXPORT SUCCEEDED` (manual signing with the installed iCloud profile, per the release memory).

- [ ] **Step 4 `[?] awaiting on-device verify`:** On the device: (a) the **Recipes tab still renders** identically (no view regression); (b) first launch **migrated existing recipes** (count + fields + images match the Fly app); (c) **create/edit/favorite/archive/delete** persist, survive force-quit (store = truth), and the "Recipes repo round-trip" debug button is green; (d) RUN ALL still green. Mark this box once Taylor confirms on-device.

- [ ] **Step 5: Commit** — `git commit -m "feat(sp-c): on-device recipe-repo check + slice-1 verification"`.

---

## Self-Review

**Spec coverage:** §1 skeleton → Tasks 2–3; §1.2 repository → Task 4; §1.3 + §5 mapper → Task 1; §4 IN/OUT scope → Task 5 (delegate IN, guard OUT); §7 façade leak → Task 5; §8 migration → Task 6; §9 verification → Task 7. §6 open items (metadata, memories, iconKey): metadata is touched via the façade (Task 5) but the *managed-list create* + memories are **deferred** per the spec recommendation — NOTE: this plan does NOT implement `recipeMetadata` population or memories; the editor's cuisine/tag dropdowns + the memories section may be empty on the CloudKit build until a follow-on. Flag this to Taylor before execution. `iconKey` folds into the record automatically via the mapper (Category-A).

**Placeholder scan:** the codebase-derived steps say "read X / mirror Y / confirm Z" by design (per AGENTS.md, not fabricating unverified bodies) — these are verification instructions, not vague TODOs. The one pure component (mapper) has complete test + implementation guidance. No "add error handling"-style placeholders.

**Type consistency:** `RecipeRecordMapper.records(from:)`/`recipe(from:)`, `HouseholdSession.store/engine/syncPhase/storeRevision`, `RecipeRepository.recipes/reload/save`, `onStoreChanged` — names are used consistently across Tasks 1–7. `SyncPhase` reused from AppState (not redefined).

**Open flag for Taylor:** this slice deliberately ships Recipes CRUD + images + migration but **defers recipe metadata population + memories + the AI recipe methods**. Those make the editor's dropdowns and the memories card thin until their follow-ons. Confirm that's an acceptable slice-1 boundary, or pull metadata into this plan.
