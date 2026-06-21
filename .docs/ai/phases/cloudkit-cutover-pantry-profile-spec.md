# SP-C — CloudKit cutover, slice 5: Pantry + Profile + Preferences

> Design spec. 2026-06-20. Fifth cutover slice. MIXED: household-zone (Pantry, aliases) + the per-user
> NSPCKC PRIVATE PLANE (Profile settings, DietaryGoal, IngredientPreference, PreferenceSignal). The
> private plane is the one genuinely-new mechanism — SP-A built the @Model types + PrivatePlaneStore
> but it is NOT YET WIRED into HouseholdSession.

## 0. Goal + scope (per-user vs household — decided from the map)
- **HOUSEHOLD-SHARED → household zone (CKSyncEngine, the familiar repository pattern):**
  `PantryItem` (staples), `HouseholdTermAlias` (assistant aliases).
- **PER-USER → NSPCKC private plane (SwiftData @Model, per-user iCloud private DB):**
  `Profile` non-AI settings (image_provider/unit_system/user_region/auto_grocery_from_meals),
  `DietaryGoal`, `IngredientPreference`, `PreferenceSignal`.

**IN:** pantry CRUD + apply-recurrings; alias CRUD; profile non-AI settings; dietary goal; ingredient
preferences; preference signals; the migration of all of these; wire the private plane; un-gate/rewire.
**OUT (→ AI track):** `saveAISettings` (BYO-key provider config + the API key → Keychain, not CloudKit;
assistant threads/messages) — the Settings "AI" section stays Fly/coming-soon until the AI track.
**OUT/dead:** subscription/usage (M5 freemium — not part of the data cutover); `applyPantryToCurrentWeek`
depends on Weeks (in place) — wire it via the WeekRepository.

## 1. What SP-A already built (wire, don't rebuild)
- **Private plane (Phase 1):** `PrivatePlaneModels` (@Model: `PrivateProfileSetting` recordKey/value,
  `PrivateDietaryGoal` singleton "dietary_goal", `PrivateIngredientPreference` recordKey=preferenceId,
  `PrivatePreferenceSignal` det "signalType:normalizedName", + assistant types [AI track], +
  `PrivateMigrationReceipt`). `makeSimmerSmithPrivatePlaneContainer` (NSPCKC, `.private(...)`).
  `PrivatePlaneStore` (fetch-before-insert upsert + accessors for each + `claimMigrationScope`).
- **Household manifest:** `.householdTermAlias` (det-keyed) exists. `.householdSetting` exists (unused
  here — profile settings go per-user). **GAP: no `.pantryItem` — ADD it (new household type → deploy).**
- **The Recipes/Weeks/Events slices' household repository pattern** to mirror for Pantry/Alias.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `.pantryItem` manifest type | new | Pantry record (pk; fields stapleName/normalizedName/notes/isActive/typicalQuantity/typicalUnit/recurringQuantity/recurringUnit/recurringCadence/category/categories[serialized]/lastAppliedAt/frozenAt/createdAt/updatedAt; no refs). Schema deploy. |
| **Private-plane wiring** | new (App/HouseholdSession.swift) | Create the NSPCKC `ModelContainer` (`makeSimmerSmithPrivatePlaneContainer`) at `start()` + expose a `PrivatePlaneStore` (its `@MainActor` ModelContext). The session already NAMES the private plane as owned — actually wire it now. NSPCKC syncs to the user's private DB automatically (no CKSyncEngine). |
| `ProfileRepository` | new (app Data/) | over the private plane: settings (PrivateProfileSetting) + dietary goal (PrivateDietaryGoal). |
| `PreferenceRepository` | new (app Data/) | over the private plane: PrivateIngredientPreference + PrivatePreferenceSignal. |
| `PantryRepository` | new (app Data/) | household zone: `.pantryItem` CRUD (mirror RecipeRepository). |
| `AliasRepository` | new (app Data/) | household zone: `.householdTermAlias` CRUD. |
| `AppState` rewire (+Pantry/+Profile/+Ingredients/+Aliases) | modify | DATA → repos; close the leaks (PantryItemEditorSheet `apiClient.fetchBaseIngredients` → the catalog façade; DietaryGoalView `apiClient.saveDietaryGoal`/`clearDietaryGoal` → ProfileRepository). AI settings (`saveAISettings`) → coming-soon/guarded. |
| migration | new | pantry+aliases → household zone (migrate transforms); profile/goal/prefs/signals → private plane (PrivatePlaneStore upserts). One-shot Fly auth (reuse the import trigger; add `migrated:pantry-profile`). |
| un-gate / debug | modify | Pantry (reached via Grocery "More") + Settings sections now work on CloudKit; a debug check (pantry round-trip + a private-plane upsert/read). |

## 3. The private-plane wiring (the novel risk)
NSPCKC is a DIFFERENT mechanism than the household CKSyncEngine — it's SwiftData over the user's PRIVATE
CloudKit DB, syncing automatically (no engine, no merger, no manual save-to-CloudKit). Wire it:
- `HouseholdSession.start()` creates `let privateContainer = try makeSimmerSmithPrivatePlaneContainer()`
  and exposes `var privateStore: PrivatePlaneStore { PrivatePlaneStore(context: privateContainer.mainContext) }`
  (@MainActor). It is PER-USER (the iCloud account), NOT keyed by householdID — every device on the
  account converges via NSPCKC. (Phase-0.5 proved NSPCKC + the CKSyncEngine stack coexist in one container.)
- The repos (Profile/Preference) read/write via `PrivatePlaneStore` (upsert-by-recordKey, save()); reads
  are SwiftData fetches. They do NOT use the household engine/merger. Reactivity: the repos can fetch on
  demand (the Settings/Pantry views aren't high-frequency) — a simple reload after writes is fine; do NOT
  over-engineer an @Observable bridge if a fetch-on-appear suffices.
- **Landmine:** the private plane uses CD_-prefixed CloudKit record types (NSPCKC auto-creates them) —
  SEPARATE from the hand-authored manifest schema. Don't try to cktool-deploy private-plane schema; NSPCKC
  manages it. Only `.pantryItem` (household zone) needs the cktool deploy.

## 4. Migration (mixed)
One-time, receipt-gated (`migrated:pantry-profile` — a private-plane receipt via `claimMigrationScope`).
One-shot Fly auth (reuse the import trigger). Pull: `/api/pantry_items` → `.pantryItem` (household);
`/api/profile` → PrivateProfileSetting (non-AI keys) + PrivateDietaryGoal; `/api/ingredient_preferences`
→ PrivateIngredientPreference; preference signals → PrivatePreferenceSignal; `/api/household` aliases →
`.householdTermAlias`. Idempotent; clear the Fly token after.

## 5. Verification
- **Headless:** the `.pantryItem` manifest migrate test; a PrivatePlaneStore upsert/fetch test (in-memory
  container, CloudKit sync off) for dietary-goal + ingredient-pref.
- **On-device (TestFlight):** (1) migrate pantry/profile/prefs/aliases; (2) Pantry: add/edit/delete/apply-
  recurrings persist; (3) Settings: dietary goal + ingredient preferences + non-AI settings save + reflect;
  (4) a 2nd device on the SAME iCloud account sees the private-plane data (NSPCKC convergence) — or note
  it's the same-account single-device check; (5) Recipes/Weeks/Events still fine.

## 6. Risks
- **Private-plane wiring** — the novel risk. NSPCKC is a different lifecycle (ModelContainer, @MainActor
  context, automatic sync). Mirror the SP-A Phase-1 DEBUG check's construction (it already inits NSPCKC
  against the real account). Don't conflate it with the household engine.
- **New `.pantryItem` type** → dashboard deploy (controller preps cktool).
- **Profile settings split** — non-AI → private plane (this slice); AI settings → AI track. Don't migrate
  the AI key into CloudKit (it belongs in Keychain — AI track owns it).
- **The Settings screen is intertwined** — rewire only the slice-5 sections (pantry/dietary/prefs/non-AI
  settings); leave the AI section + subscription as-is (coming-soon/Fly) with markers.
