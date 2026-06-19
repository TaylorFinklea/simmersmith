# SP-C — CloudKit cutover, slice 1: Recipes (+ the reusable data-layer skeleton)

> Design spec. Brainstormed + approved 2026-06-19. Source-of-truth for the first cutover slice.
> Terse where the codebase already shows the pattern; exact where drift would cost a re-dispatch.

## 0. Goal + strategy (the frame this slice lives in)

**End state:** the iOS app's data plane runs entirely on CloudKit (the SP-A data plane, already built
+ on-device-verified), and **Fly is dropped from new builds**. AI runs off-device-server too
(BYO-key + on-device hybrid). No incremental release / no Fly fallback inside the new build.

**Transition safety (decided):** Taylor runs the all-CloudKit build; **Savanne stays on the current
Fly build** as the untouched fallback. The two data planes do NOT sync during the transition (split
household — Taylor dogfoods CloudKit solo). When parity is reached, Savanne migrates + joins Taylor's
household via CKShare (Phase 2c flow), then Fly is retired (SP-D).

**Work shape:** full parity is too big for one spec, so it's decomposed into per-feature slices, each
its own spec → plan → build, all reusing the skeleton this slice establishes. **Recipes is slice 1**
(chosen: self-contained, exercises record CRUD + CKAsset + sync without the grocery field-merge).

**AI is a parallel track** (its own spec): implement the real `OnDeviceProvider` (Foundation Models,
iOS 26) + `BYOKeyProvider` (direct OpenAI/Anthropic, key in Keychain) behind the existing
`AIProviderKit.ProviderRouter`. This slice DEFERS every AI-dependent recipe method to that track
(see §4 scope).

## 1. Architecture — the reusable CloudKit data backbone

Three planes, one long-lived owner, per-feature repositories behind the existing AppState facade.

### 1.1 `HouseholdSession` (new, long-lived; created once at launch)
Owns and starts the planes; replaces the throwaway engines the DEBUG panel builds. Lives for the app
lifetime, injected into AppState. Responsibilities:
- **Household plane** — one `HouseholdSyncEngine` + `HouseholdLocalStore` over the household zone
  (the user's PRIVATE db as owner, or the SHARED db as participant). Custom CKSyncEngine stack
  because it is merge-safe (grocery/event field-merge); NSPCKC is **not** used here (Spike-1 verdict).
  Wires the `DispatchingMerger([Grocery, EventGrocery, Event])` seam (as the DEBUG checks do).
- **Private plane** — `NSPersistentCloudKitContainer` (`makeSimmerSmithPrivatePlaneContainer`, already
  built) for per-user data (profile/prefs/assistant transcript). Out of scope for slice 1; named so
  the session owns it from the start.
- **Catalog** — `PublicCatalogReader` (already built) for ingredient/template catalog reads.
- **Bootstrap:** on first launch ensure the household zone exists (`HouseholdZoneProvisioner`), then
  `fetchChanges()` to hydrate the local store before the UI reads it. Surface a `SyncPhase`
  (.loading/.synced(Date)/.offline/.failed) that AppState already exposes to views.
- **Change signal:** expose an async stream / callback that fires when `handleEvent`'s
  `fetchedRecordZoneChanges`/`sentRecordZoneChanges` mutate the local store, so repositories can
  refresh. (The engine's delegate already sees these events — add a published "store changed" hook;
  do NOT poll.)

> Codebase-derived: mirror exactly how `CloudKitDebugView.runHouseholdSyncCheck` constructs the
> engine + store + merger; the difference is lifetime (one shared instance) + the change hook. Read
> `HouseholdSyncEngine` before writing the hook — extend its delegate handling, don't fork it.

### 1.2 Per-feature repository pattern (established here by `RecipeRepository`)
A repository is a feature's data API. It is the ONLY thing that touches the store/engine for its
types. Contract every repository follows:
- **Reads** come from the local store (offline-first — the store is the source of truth; sync is
  background). `store.records(ofType:)` → decode → map to domain structs.
- **Writes** map domain struct → record(s) → `engine.save` / `engine.deleteCascading` (syncs).
- **Reactive state:** the repo holds the feature's `@Observable` projection (e.g. the recipe array)
  and recomputes it from the store on the session's change signal.
- **AppState stays the façade:** views + the assistant keep calling AppState; AppState's data methods
  **delegate to the repo** instead of issuing HTTP. Views and the domain structs do NOT change.

### 1.3 Domain↔record mapper (new; the load-bearing piece)
The migration transforms only go Postgres-row → record. Live CRUD needs **both directions on the
DOMAIN struct**: `RecipeSummary ⇄ HouseholdRecordValue (+ children + image)`. This is §5.

## 2. Why not the alternatives (recorded so we don't relitigate)
- **NSPCKC for household data:** rejected — blanket LWW corrupts the sticky grocery field-merge
  (Spike 1). The custom stack is mandatory for the household plane. NSPCKC = private plane only.
- **Views observe the store directly (drop AppState):** rejected for now — churns every view + the
  assistant integration for no data-correctness gain. AppState-as-façade keeps the UI stable while we
  prove the data layer. Revisit only if the façade becomes the bottleneck.

## 3. Components to build (slice 1)
| Component | Location (new unless noted) | Responsibility |
|---|---|---|
| `HouseholdSession` | app target, `App/` | Owns + boots the three planes; exposes SyncPhase + change signal |
| store change hook | `SimmerSmithCloudKit/.../HouseholdSyncEngine.swift` (extend) | Fire on local-store mutation from sync |
| `RecipeRepository` | app target, `Features/Forge/` or `Data/` | Recipe CRUD + image + metadata + memories over the store |
| `RecipeRecordMapper` | app target or a thin Kit module | `RecipeSummary ⇄ records (+ children + image)`, both directions |
| `AppState+Recipes` rewire | existing file | Delegate data methods to `RecipeRepository`; keep signatures |
| `fetchBaseIngredients` façade | `AppState` (new wrapper) | Close the `RecipeEditorView`→`apiClient` leak (§7) |
| First-launch recipe migration | reuse `HouseholdMigrationRunner` | Pull recipes from Fly GET → migrate → CloudKit, once |

## 4. Scope of slice 1 — IN vs OUT (explicit, to prevent over-reach)
**IN (the recipe data plane on CloudKit):**
- List/detail: `refreshRecipes`, `fetchRecipe` → read from store.
- Mutations: `saveRecipe(draft)` (create/update, incl. favorite toggle + variant `baseRecipeId`),
  `archiveRecipe`, `restoreRecipe`, `deleteRecipe` (cascading) → write via engine.
- Header image: `uploadRecipeImage`, `deleteRecipeImage`, `fetchRecipeImageBytes` → `RecipeImageCodec`
  CKAsset (the read path is on-sim-verified in Phase 3).
- Recipe metadata (`recipeMetadata`: cuisines/tags/units, `createManagedListItem`) — see §6 open item.
- Recipe memories (`refreshRecipeMemories`/`createRecipeMemory`/`deleteRecipeMemory` + memory photo)
  — see §6 open item (RecipeMemory is not yet a manifest type).

**OUT (deferred to the AI track — they require a model, not data):**
- `importRecipeDraft` (URL/HTML/text), `searchRecipeOnWeb`, `generateRecipeVariationDraft`,
  `generateRecipeSuggestionDraft`, `refineRecipeDraft`, `estimateRecipeNutrition`,
  `regenerateRecipeImage`/`backfillRecipeImages` (AI image gen).
- In slice 1 these stay calling Fly (still up during transition) OR are disabled behind a feature
  guard. They get rewired to `AIProviderKit` when the AI track lands. Document which choice per
  method in the plan; do NOT silently leave them pointing at a Fly URL that will 404 post-SP-D.

## 5. The mapper contract — `RecipeSummary ⇄ records` (spec-derived; get this exact)
`RecipeSummary` (SimmerSmithKit `SimmerSmithModels.swift:1750`) has more fields than the `.recipe`
manifest record because several are **server-computed/denormalized**. Classify every field:

**A. Direct scalar ⇄ `.recipe` record field** (1:1, names already align via the manifest):
`recipeId`↔recordName, `name`, `mealType`, `cuisine`, `servings`, `prepMinutes`, `cookMinutes`,
`instructionsSummary`, `favorite`, `archived`, `source`, `sourceLabel`, `sourceUrl`↔`sourceURL`,
`notes`, `memories`, `iconKey`, `lastUsed`, `difficultyScore`, `kidFriendly`, `archivedAt`,
`updatedAt`. (Confirm each against `HouseholdRecordType.recipe.fields` before coding — the manifest is
the authority; `migrateHouseholdRecord` already proves the column names.)

**B. Serialized scalar** — `tags: [String]` (struct) ↔ `tags: string` (record). Decide + PIN the
serialization in the plan (the Postgres `tags` is Text; match whatever the migration transform reads
so migrated + live recipes agree — likely a delimiter or JSON array). The mapper owns
encode/decode; cover empty + multi-tag in a unit test.

**C. References** — `baseRecipeId` ↔ `baseRecipe` ref (`.setNullInZone`, NOT cascade — variants
survive base deletion); `recipeTemplateId` ↔ `recipeTemplateID` (`.crossDBString`, a plain String key
into PUBLIC). `overridePayloadJSON` (the variant override) ↔ the record's `overridePayloadJSON` scalar.

**D. Child records** — `ingredients: [RecipeIngredient]` ↔ `.recipeIngredient` records (each
`recipe` = `.cascadeParent`); `steps: [RecipeStep]` ↔ `.recipeStep` records (`recipe` cascade +
`parentStep` cascade self-ref for substeps). On save: diff the child set, save changed, delete
removed (cascading is for whole-recipe delete; per-child removal is an explicit delete). Map the
child struct fields per the manifest (`RecipeIngredient`/`RecipeStep` fields documented in the
SP-A manifest).

**E. Image** — `imageUrl: String?` has no CloudKit analog. Replace with "does a `RecipeImage`
(`rimg:<recipeId>`) record exist?"; the view fetches bytes via `RecipeImageCodec`/the repo, not a URL.
The editor's upload/delete go through `RecipeImageCodec`.

**F. Computed/derived — NOT stored in the record; compute client-side or omit in slice 1:**
`daysSinceLastUsed`/`familyDaysSinceLastUsed` (from `lastUsed`/`familyLastUsed` + now),
`familyLastUsed` (household aggregate — recompute from the household's usage, or defer),
`isVariant`/`variantCount`/`sourceRecipeCount`/`overrideFields` (from the variant graph — compute by
scanning `baseRecipe` refs in the store), `nutritionSummary` (computed from ingredients × catalog —
**defer to a nutrition pass**; return nil in slice 1 so the detail view's nutrition card is
empty/hidden rather than wrong). The plan must state, per derived field, "compute from store" vs
"nil/defer" so the implementer doesn't fabricate values.

> Mapper invariant (unit-tested headlessly, no account): `record(of: map(recipe))` round-trips the
> Category-A/B/C/D fields; derived fields are recomputed, not persisted.

## 6. Open items to resolve in the plan (flagged, not yet decided)
1. **Recipe metadata source.** `recipeMetadata` (cuisines/tags/units, `ManagedListItem`) is reference
   data. Options: (a) PUBLIC catalog read (ManagedListItem is in the §8.1 seed list) — needs the type
   seeded to prod like the catalog; (b) a household-zone record set the user manages. Pick one in the
   plan; lowest-effort that preserves the editor's dropdowns wins.
2. **Recipe memories.** `RecipeMemory` is NOT a manifest type yet. Either add it (a household record
   type + its CKAsset photo, mirroring RecipeImage) or defer memories from slice 1 (hide the section).
   Recommend: defer memories to a thin follow-on so slice 1 stays the core CRUD pattern.
3. **`iconKey` override.** Currently `RecipeIconOverrides.shared` (local UserDefaults). The `.recipe`
   record has an `iconKey` field — fold the override into the record (syncs across devices) or keep
   local. Recommend fold into the record.

## 7. The façade leak to close
`RecipeEditorView.swift:~670` calls `appState.apiClient.fetchBaseIngredients(query:limit:)` directly,
bypassing AppState. Add an `AppState` wrapper that, in the CloudKit build, resolves against the
`PublicCatalogReader` + the household zone (the §8.2 resolve order). The view calls the wrapper. This
is the only known direct-`apiClient` call in the recipe views; grep for others before finishing.

## 8. First-launch migration (recipes)
On first launch of the CloudKit build, if the household zone has no `MigrationReceipt` for the recipe
scope: pull the user's recipes from Fly via the **existing GET `/api/recipes?include_archived=true`**
(+ per-recipe detail for ingredients/steps if the list omits them), shape rows into the
`HouseholdMigrationRunner.Export.householdRecords[.recipe/.recipeIngredient/.recipeStep]`, run the
migration (idempotent, receipt-gated — already built + on-device-verified), and pull each recipe's
image bytes → `RecipeImageCodec`. No new Fly endpoint. The full migration grows per slice; slice 1
migrates recipes only. (Whole-app migration orchestration is its own concern at parity time.)

## 9. Verification (how we know slice 1 is done)
- **Headless (CI, no account):** mapper round-trip test (§5 invariant); child diff (add/remove
  ingredient/step) produces the right save/delete set; tags serialization edge cases.
- **On-device (TestFlight, Production CloudKit, the proven path):** (1) fresh install migrates the
  user's existing recipes from Fly into CloudKit (count matches, fields intact, images present);
  (2) create a recipe in the app → it persists offline → appears after force-quit (store is truth) →
  syncs (visible via a 2nd engine / the DEBUG panel); (3) edit/favorite/archive/delete reflect +
  sync; (4) the recipe list/detail/editor render identically to the Fly build (no view regression).
- **Parity check:** every IN-scope `AppState+Recipes` method behaves the same to the views as the Fly
  version (same signatures, same observable updates).

## 10. After slice 1 (the sequence this skeleton unlocks)
Recipes → Weeks + WeekMeals + Grocery (the field-merge core; reuses the repo/mapper/migration
skeleton + the `merger` seam) → Events + EventMeals + EventGrocery → Pantry/Profile/Ingredient
preferences (private plane) + catalog resolve → the AI track (real providers) → migration
completeness across all features → drop Fly (SP-D). Each is its own spec/plan.

## 11. Risks / landmines
- **Split household during transition** — accepted; Taylor solo on CloudKit, Savanne on Fly, reunite
  via CKShare at parity. Don't build cross-plane sync.
- **Computed fields fabricated** — the mapper must NOT invent values for derived fields (§5-F); nil or
  client-compute, never a guess that the UI shows as truth.
- **AI methods silently 404** — deferred AI methods must be guarded, not left pointing at a Fly URL
  that dies at SP-D (§4).
- **CloudKit-write-needs-pending-edit seam** — live edits go through the engine's documented save path
  (same as the DEBUG checks); the field-merge gating (Phase 5 fix) only matters for grocery, not
  recipes (plain LWW), but reuse the engine as-is.
- **Don't promote new record types to prod without the dashboard deploy** — any new type (e.g. a
  RecipeMemory) needs the CloudKit Dashboard "Deploy to Production" step (cktool can't); fold into the
  plan if §6.2 adds a type.
