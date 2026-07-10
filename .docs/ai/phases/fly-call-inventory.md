# Fly-call inventory — every production `apiClient.*` call site, classified

> Bead `simmersmith-8xz`. Generated 2026-07-09 by a 4-way mechanical enumeration + adversarial
> verification of every LIVE-AND-BROKEN row. **This file supersedes ADR-1's prose list of seven
> Fly-backed features**, which was wrong: it omitted meal feedback (`b9z`), grocery feedback,
> and Plan Shopping (`4ii`). Bead `990.8` (strip Fly fallback branches) must work from THIS
> table, not from prose.

## Method

For every `apiClient.<method>(` call site in `SimmerSmith/SimmerSmith` (tests excluded), an agent
read the **full enclosing function and every early-return above the call**, then classified it.
Each LIVE-AND-BROKEN row was then handed to an independent verifier told to *refute* it by
finding a guard, and to confirm the user entry point by grepping `Features/`. Rows below survived.

| class | count | meaning |
|---|---|---|
| **LIVE-AND-BROKEN** | **24** | reachable on a CloudKit household; hits the dead backend. **Gate-2: port or hide.** |
| GUARDED-DEAD | 70 | a CloudKit branch returns before the call. Safe for `990.8` to strip. |
| PORTED-ALREADY | 46 | CloudKit impl exists; the call is a legacy `hasSavedConnection` fallback. |
| DEV-ONLY | 0 | reachable only from a DEBUG/CloudKitDebugView surface. |
| **total** | **140** | |

## LIVE-AND-BROKEN — the Gate-2 set

Each row is a visible feature that lies. Grouped by the bead that owns it.

### Feedback loop → bead `b9z`

| method | site | user entry point |
|---|---|---|
| `submitFeedback` | `App/AppState+Weeks.swift:578` | Features/Week/WeekView.swift:417 — .sheet(item: $feedbackMeal) { FeedbackCompose |
| `submitFeedback` | `App/AppState+Weeks.swift:602` | Features/Grocery/GroceryFeedbackSheet.swift:206 — save() calls `try await appSta |

### Plan Shopping → bead `4ii`

| method | site | user entry point |
|---|---|---|
| `planShopping` | `App/AppState+Grocery.swift:183` | Features/Grocery/PlanShoppingSheet.swift:237 — `let response = try await appStat |

### Recipe memories → bead `990.4.2`

| method | site | user entry point |
|---|---|---|
| `fetchRecipeMemories` | `App/AppState+Recipes.swift:1169` | Features/Recipes/RecipeMemoriesSection.swift:135 (load(), run from .task(id: rec |
| `createRecipeMemory` | `App/AppState+Recipes.swift:1184` | Features/Recipes/MemoryComposeSheet.swift:115, presented from RecipeMemoriesSect |
| `fetchRecipeMemoryPhotoBytes` | `App/AppState+Recipes.swift:1200` | Features/Recipes/MemoryPhotoView.swift:34, shown for any memory row with a photo |
| `deleteRecipeMemory` | `App/AppState+Recipes.swift:1207` | Features/Recipes/RecipeMemoriesSection.swift:144 (delete(), swipe/confirm-delete |

### Ingredients / nutrition → beads `990.5.1` · `990.5.2` · `990.5.3`

The largest cluster. `990.5.1`'s note already called `IngredientLinkPickerSheet` "fully dead-backend";
this is the full extent of it.

| method | site | user entry point |
|---|---|---|
| `fetchBaseIngredients` | `App/AppState+Ingredients.swift:14` | Features/Ingredients/IngredientsView.swift:91 (loadIngredients); Features/Settin |
| `fetchIngredientVariations` | `App/AppState+Ingredients.swift:26` | Features/Settings/SettingsView.swift:1190 (IngredientPreferenceEditorSheet.selec |
| `fetchBaseIngredientDetail` | `App/AppState+Ingredients.swift:30` | Features/Ingredients/IngredientsView.swift:388 (IngredientDetailView.loadDetail, |
| `createBaseIngredient` | `App/AppState+Ingredients.swift:48` | Features/Ingredients/IngredientsView.swift:593 (BaseIngredientEditorSheet.save); |
| `updateBaseIngredient` | `App/AppState+Ingredients.swift:81` | Features/Ingredients/IngredientsView.swift:580 (BaseIngredientEditorSheet.save,  |
| `archiveBaseIngredient` | `App/AppState+Ingredients.swift:100` | Features/Ingredients/IngredientsView.swift:154 (IngredientDetailView archive-con |
| `mergeBaseIngredient` | `App/AppState+Ingredients.swift:104` | Features/Ingredients/BaseIngredientMergeSheet.swift:131 (merge()) |
| `createIngredientVariation` | `App/AppState+Ingredients.swift:127` | Features/Ingredients/IngredientsView.swift:757 (IngredientVariationEditorSheet.s |
| `updateIngredientVariation` | `App/AppState+Ingredients.swift:170` | Features/Ingredients/IngredientsView.swift:739 (IngredientVariationEditorSheet.s |
| `archiveIngredientVariation` | `App/AppState+Ingredients.swift:194` | Features/Ingredients/IngredientsView.swift:322 (productsSection onArchiveVariati |
| `mergeIngredientVariation` | `App/AppState+Ingredients.swift:198` | none — grep for mergeIngredientVariation across the whole repo returns only this |
| `resolveIngredient` | `App/AppState+Ingredients.swift:202` | Features/Recipes/RecipeEditorIngredientResolution.swift:364 (loadSuggestedResolu |
| `saveIngredientNutritionMatch` | `App/AppState+Ingredients.swift:311` | Features/Recipes/RecipeNutritionMatchView.swift:108 (saveMatch), reached UNGATED |
| `fetchBaseIngredients` | `App/AppState+Recipes.swift:1875` | Features/Grocery/IngredientLinkPickerSheet.swift:178 (search()), auto-triggered  |
| `createBaseIngredient` | `Features/Grocery/IngredientLinkPickerSheet.swift:192` | Features/Grocery/GroceryFeedbackSheet.swift:136, Features/Grocery/GroceryItemEdi |
| `patchGroceryItem` | `Features/Grocery/IngredientLinkPickerSheet.swift:212` | Features/Grocery/GroceryFeedbackSheet.swift:136, Features/Grocery/GroceryItemEdi |
| `submitIngredientForAdoption` | `Features/Ingredients/IngredientsView.swift:564` | Features/Ingredients/IngredientsView.swift:62 and :166 (BaseIngredientEditorShee |

## GUARDED-DEAD — safe for `990.8` to strip

| method | site | guard |
|---|---|---|
| `updateProfile` | `App/AppState+AI.swift:95` | Lines 22-73: `if let repo = profileRepository, let aiSvc = aiService { ... lastErrorMessag |
| `fetchHealth` | `App/AppState+AI.swift:100` | Same guard as the updateProfile call in this function: lines 22-73's `if let repo = profil |
| `fetchGuests` | `App/AppState+Events.swift:20` | Lines 11-17: `if let repo = guestRepository { repo.reload(); mirrorGuestsFromRepository(); |
| `upsertGuest` | `App/AppState+Events.swift:51` | Lines 37-49: `if let repo = guestRepository { ...; return updated }` returns before the ap |
| `deleteGuest` | `App/AppState+Events.swift:78` | Lines 71-76: `if let repo = guestRepository { repo.deleteGuest(...); mirrorGuestsFromRepos |
| `fetchEvents` | `App/AppState+Events.swift:94` | Lines 85-90: `if let repo = eventRepository { repo.reload(); mirrorEventsFromRepository(); |
| `fetchEvent` | `App/AppState+Events.swift:116` | Lines 102-114: `if let repo = eventRepository { repo.reload(); ...; if let event = repo.ev |
| `createEvent` | `App/AppState+Events.swift:151` | Lines 131-149: `if let repo = eventRepository { guard let event = repo.createEvent(...) el |
| `updateEvent` | `App/AppState+Events.swift:197` | Lines 175-195: `if let repo = eventRepository { guard let event = repo.updateEvent(...) el |
| `deleteEvent` | `App/AppState+Events.swift:221` | Lines 213-219: `if let repo = eventRepository { repo.deleteEvent(...); eventSummaries.remo |
| `addEventMeal` | `App/AppState+Events.swift:257` | Lines 236-255: `if let repo = eventRepository { guard let event = repo.addEventMeal(...) e |
| `updateEventMeal` | `App/AppState+Events.swift:306` | Lines 283-304: `if let repo = eventRepository { guard let event = repo.updateEventMeal(... |
| `deleteEventMeal` | `App/AppState+Events.swift:337` | Lines 324-335: `if let repo = eventRepository { guard let event = repo.deleteEventMeal(... |
| `addEventSupplement` | `App/AppState+Events.swift:362` | Lines 355-360: `if isCloudKitOnly { throw NSError(..."Pantry supplements are coming soon." |
| `patchEventSupplement` | `App/AppState+Events.swift:391` | Lines 384-389: same `if isCloudKitOnly { throw ... }` guard, always-true per cloudKitOnlyB |
| `deleteEventSupplement` | `App/AppState+Events.swift:412` | Lines 405-410: same `if isCloudKitOnly { throw ... }` guard, always-true per cloudKitOnlyB |
| `refreshEventGrocery` | `App/AppState+Events.swift:435` | Lines 421-433: `if let repo = eventRepository { repo.refreshEventGrocery(...); mirrorEvent |
| `mergeEventGroceryIntoWeek` | `App/AppState+Events.swift:456` | Lines 443-454: `if let repo = eventRepository { guard let event = repo.mergeEventGroceryIn |
| `unmergeEventGroceryFromWeek` | `App/AppState+Events.swift:477` | Lines 464-475: `if let repo = eventRepository { guard let event = repo.unmergeEventGrocery |
| `dedupeGrocery` | `App/AppState+Grocery.swift:303` | #if canImport(CloudKit) block (lines 294-301) returns via groceryRepo.dedupe when groceryR |
| `upsertIngredientPreference` | `App/AppState+Ingredients.swift:274` | #if canImport(CloudKit) if let repo = preferenceRepository { ...; return repo.preferences. |
| `updateProfile` | `App/AppState+Profile.swift:43` | `#if canImport(CloudKit) if let repo = profileRepository { repo.setSetting(...); return }` |
| `updateProfile` | `App/AppState+Profile.swift:75` | Identical pattern to saveImageProvider: `if let repo = profileRepository { ...; return }`  |
| `updateProfile` | `App/AppState+Profile.swift:113` | Identical pattern: `if let repo = profileRepository { ...; return }` (lines 104-108) prece |
| `saveDietaryGoal` | `App/AppState+Profile.swift:140` | `if let repo = profileRepository { repo.saveDietaryGoal(goal); return }` (lines 127-135) p |
| `clearDietaryGoal` | `App/AppState+Profile.swift:160` | `if let repo = profileRepository { repo.clearDietaryGoal(); return }` (lines 151-155) prec |
| `fetchRecipe` | `App/AppState+Recipes.swift:1020` | #if canImport(CloudKit) if let repo = recipeRepository { ...; return summary } (or throws  |
| `fetchRecipeImageBytes` | `App/AppState+Recipes.swift:1041` | #if canImport(CloudKit) if let repo = recipeRepository { ...; return data (or throw 404) } |
| `regenerateRecipeImage` | `App/AppState+Recipes.swift:1068` | #if canImport(CloudKit) if let repo = recipeRepository, let aiSvc = aiService { ...; retur |
| `uploadRecipeImage` | `App/AppState+Recipes.swift:1082` | #if canImport(CloudKit) if let repo = recipeRepository { repo.setImage(...); return } — al |
| `deleteRecipeImage` | `App/AppState+Recipes.swift:1100` | #if canImport(CloudKit) if let repo = recipeRepository { repo.removeImage(...); return } — |
| `backfillRecipeImages` | `App/AppState+Recipes.swift:1156` | #if canImport(CloudKit) if let repo = recipeRepository, let aiSvc = aiService { ...; retur |
| `createManagedListItem` | `App/AppState+Recipes.swift:1237` | #if canImport(CloudKit) if let repo = metadataRepository { let item = try repo.createManag |
| `estimateRecipeNutrition` | `App/AppState+Recipes.swift:1305` | #if canImport(CloudKit) if let catalog = householdSession?.catalog { ...; return calculato |
| `searchNutritionItems` | `App/AppState+Recipes.swift:1345` | Same householdSession?.catalog guard as estimateRecipeNutrition (catalog is a non-optional |
| `importRecipe` | `App/AppState+Recipes.swift:1381` | This apiClient call sits in the #else branch of `#if canImport(CloudKit)` wrapping the who |
| `importRecipe` | `App/AppState+Recipes.swift:1410` | Same compile-time #else-branch pattern as line 1381 — never compiled into the shipping bui |
| `generateRecipeVariationDraft` | `App/AppState+Recipes.swift:1447` | Compile-time #else branch of #if canImport(CloudKit); the #if branch (on-device LLM variat |
| `suggestPairings` | `App/AppState+Recipes.swift:1454` | No internal guard in AppState+Recipes.swift itself, but the ONLY UI entry point is gated b |
| `searchRecipeOnWeb` | `App/AppState+Recipes.swift:1478` | Compile-time #else branch of #if canImport(CloudKit); the #if branch (on-device web-search |
| `generateRecipeSuggestionDraft` | `App/AppState+Recipes.swift:1514` | Compile-time #else branch of #if canImport(CloudKit). |
| `generateSideRecipeDraft` | `App/AppState+Recipes.swift:1544` | Compile-time #else branch of #if canImport(CloudKit); the #if branch delegates to generate |
| `generateRecipeCompanionDrafts` | `App/AppState+Recipes.swift:1583` | Compile-time #else branch of #if canImport(CloudKit). |
| `suggestIngredientSubstitutions` | `App/AppState+Recipes.swift:1775` | Compile-time #else branch of #if canImport(CloudKit); the #if branch (on-device LLM substi |
| `saveRecipe` | `App/AppState+Recipes.swift:1799` | #if canImport(CloudKit) if let repo = recipeRepository { let saved = try repo.save(draft); |
| `fetchRecipeMetadata` | `App/AppState+Recipes.swift:1805` | Nested best-effort Task inside the same Fly-fallback block as line 1799 (after `let savedR |
| `refineRecipeDraft` | `App/AppState+Recipes.swift:1847` | Compile-time #else branch of #if canImport(CloudKit); the #if branch (on-device LLM refine |
| `archiveRecipe` | `App/AppState+Recipes.swift:1947` | #if canImport(CloudKit) if let repo = recipeRepository { repo.archive(...); return } alway |
| `restoreRecipe` | `App/AppState+Recipes.swift:1962` | #if canImport(CloudKit) if let repo = recipeRepository { repo.restore(...); return } alway |
| `deleteRecipe` | `App/AppState+Recipes.swift:1982` | #if canImport(CloudKit) if let repo = recipeRepository { repo.delete(...); return } always |
| `fetchRecipes` | `App/AppState+Recipes.swift:1985` | Same recipeRepository check as line 1982 (this is the post-delete refetch inside the same  |
| `checkGroceryItem` | `App/AppState+Reminders.swift:385` | `#if canImport(CloudKit) if let groceryRepo = groceryRepository { groceryRepo.toggleChecke |
| `uncheckGroceryItem` | `App/AppState+Reminders.swift:386` | Same guard/reasoning as the checkGroceryItem row above (ternary's other branch, same funct |
| `addGroceryItem` | `App/AppState+Reminders.swift:416` | `#if canImport(CloudKit) if let groceryRepo = groceryRepository { ...; return }` (lines 40 |
| `fetchSeasonalProduce` | `App/AppState+Seasonal.swift:48` | Line 48 sits in the `#else` branch of `#if canImport(CloudKit) ... #else return try await  |
| `updateProfile` | `App/AppState+Seasonal.swift:89` | Lines 78-84: `if let repo = profileRepository { repo.setSetting("user_region", trimmed); u |
| `identifyIngredient` | `App/AppState+Vision.swift:41` | Line 41 sits in the `#else` branch of `#if canImport(CloudKit) ... #else ... #endif` (line |
| `cookCheck` | `App/AppState+Vision.swift:84` | Lines 83-90 sit in the `#else` branch of `#if canImport(CloudKit) ... #else ... #endif` (l |
| `fetchWeeks` | `App/AppState+Weeks.swift:97` | #if canImport(CloudKit) block (lines 64-95) returns a WeekSummary projection built from we |
| `fetchWeekByStart` | `App/AppState+Weeks.swift:145` | #if canImport(CloudKit) block (lines 140-144) returns `repo.week(forStart:)` when weekRepo |
| `createWeek` | `App/AppState+Weeks.swift:168` | #if canImport(CloudKit) block (lines 150-166) returns the CloudKit-created WeekSnapshot wh |
| `updateWeekMeals` | `App/AppState+Weeks.swift:270` | #if canImport(CloudKit) block (lines 255-268) returns via repo.saveWeekMeals when weekRepo |
| `addMealSide` | `App/AppState+Weeks.swift:306` | #if canImport(CloudKit) block (lines 289-304) returns via repo.addMealSide when weekReposi |
| `patchMealSide` | `App/AppState+Weeks.swift:342` | #if canImport(CloudKit) block (lines 323-340) returns via repo.updateMealSide when weekRep |
| `deleteMealSide` | `App/AppState+Weeks.swift:365` | #if canImport(CloudKit) block (lines 350-363) returns via repo.deleteMealSide when weekRep |
| `fetchWeek` | `App/AppState+Weeks.swift:370` | This private helper has no guard of its own, but all 4 call sites are transitively guarded |
| `approveWeek` | `App/AppState+Weeks.swift:399` | #if canImport(CloudKit) block (lines 385-397) returns via repo.approveWeek when weekReposi |
| `regenerateGrocery` | `App/AppState+Weeks.swift:431` | #if canImport(CloudKit) block (lines 414-429) returns via groceryRepo.regenerate + weekRep |
| `generateWeekPlan` | `App/AppState+Weeks.swift:566` | #if canImport(CloudKit) block (lines 561-564) returns `try await generateWeek(...)` when ` |
| `signInWithApple` | `App/AppState.swift:446` | No internal guard, but the function has zero callers anywhere in the app — grepped `.signI |

## PORTED-ALREADY — legacy fallback behind `hasSavedConnection`

| method | site | guard |
|---|---|---|
| `fetchProviderModels` | `App/AppState+AI.swift:195` | Unlike the other calls in this file, refreshAIModels(for:) has NO repository/CloudKit chec |
| `signInWithApple` | `App/AppState+FactoryReset.swift:100` | This whole extension (and this function) has no internal hasSavedConnection/repo guard — i |
| `addGroceryItem` | `App/AppState+Grocery.swift:23` | #if canImport(CloudKit) block (lines 10-18) returns via groceryRepo.addItem when currentWe |
| `patchGroceryItem` | `App/AppState+Grocery.swift:83` | #if canImport(CloudKit) block (lines 46-74) returns via groceryRepo.editItem/removeItem/re |
| `patchEvent` | `App/AppState+Grocery.swift:135` | #if canImport(CloudKit) block (lines 123-131) returns via eventRepository.toggleEventAutoM |
| `quickAddGroceryItem` | `App/AppState+Grocery.swift:247` | #if canImport(CloudKit) block (lines 212-234) returns via groceryRepo.addItem when grocery |
| `patchGroceryItem` | `App/AppState+Grocery.swift:278` | #if canImport(CloudKit) block (lines 265-272) returns via groceryRepo.setStoreLabel when c |
| `clearAutoGrocery` | `App/AppState+Grocery.swift:330` | Sole guard in this function is `guard hasSavedConnection, let weekID = currentWeek?.weekId |
| `reresolveUnresolvedIngredients` | `App/AppState+Grocery.swift:359` | #if canImport(CloudKit) block (lines 354-356) returns early via `if recipeRepository != ni |
| `fetchRecipes` | `App/AppState+Grocery.swift:360` | Same enclosing function/guards as line 359 (CK block lines 354-356 return; guard hasSavedC |
| `fetchCurrentWeek` | `App/AppState+Grocery.swift:362` | Same enclosing function/guards as line 359 (CK block lines 354-356 return; guard hasSavedC |
| `fetchIngredientPreferences` | `App/AppState+Ingredients.swift:220` | #if canImport(CloudKit) if let repo = preferenceRepository { repo.reload(); ...; return }  |
| `signInWithApple` | `App/AppState+Recipes.swift:762` | One-shot Fly->CloudKit weeks-import recovery flow. The entire Import*/Start Fresh Settings |
| `signInWithApple` | `App/AppState+Recipes.swift:855` | Same gate as importWeeksFromFly (SettingsView.swift:629, hasSavedConnection // hasLegacyFl |
| `signInWithApple` | `App/AppState+Recipes.swift:934` | Same gate as importWeeksFromFly (SettingsView.swift:629) — hidden for fresh CloudKit-only  |
| `fetchRecipeMetadata` | `App/AppState+Recipes.swift:990` | #if canImport(CloudKit) if let repo = recipeRepository { ...; return } returns first (reci |
| `fetchRecipes` | `App/AppState+Recipes.swift:991` | Same repo-branch + hasSavedConnection guard as line 990 (both calls are sequential in the  |
| `fetchRecipeMetadata` | `App/AppState+Recipes.swift:1221` | #if canImport(CloudKit) if let repo = metadataRepository { ...; return } returns first; th |
| `fetchCurrentWeek` | `App/AppState+Weeks.swift:29` | #if canImport(CloudKit) block (lines 17-24) returns early via weekRepository.reload()+mirr |
| `fetchWeekExports` | `App/AppState+Weeks.swift:33` | Same enclosing function/guard as line 29 (CK block lines 17-24 return; guard hasSavedConne |
| `createWeek` | `App/AppState+Weeks.swift:135` | #if canImport(CloudKit) block (lines 105-110) returns `week` unchanged as a no-op when wee |
| `checkGroceryItem` | `App/AppState+Weeks.swift:641` | #if canImport(CloudKit) block (lines 625-633) returns via groceryRepo.toggleChecked when c |
| `uncheckGroceryItem` | `App/AppState+Weeks.swift:642` | Same enclosing function/guard as line 641 (CK block lines 625-633 return; guard hasSavedCo |
| `fetchHealth` | `App/AppState.swift:474` | refreshAll() opens with `guard hasSavedConnection else { syncPhase = .idle; return }` (App |
| `fetchProfile` | `App/AppState.swift:477` | Same outer `guard hasSavedConnection else { return }` (line 465) gates the whole function; |
| `fetchCurrentWeek` | `App/AppState.swift:478` | Same outer `guard hasSavedConnection else { return }` (line 465) gates the whole function; |
| `fetchWeekExports` | `App/AppState.swift:513` | Same outer `guard hasSavedConnection else { return }` (line 465) gates the whole function; |
| `fetchRecipeMetadata` | `App/AppState.swift:525` | Nested inside `#if canImport(CloudKit) if recipeRepository == nil { ... }` (lines 520-529) |
| `fetchRecipeMetadata` | `App/AppState.swift:531` | The `#else` (non-CloudKit-platform) compile branch of the same block as line 525; on iOS t |
| `fetchIngredientPreferences` | `App/AppState.swift:547` | Nested `else if` inside `#if canImport(CloudKit) if let prefRepo = preferenceRepository {  |
| `fetchIngredientPreferences` | `App/AppState.swift:551` | The `#else` (non-CloudKit-platform) compile branch mirroring line 547; never compiles in o |
| `fetchGuests` | `Data/EventMigrationLoader.swift:76` | Receipt-gated at this file's line 69. Only reachable via `importEventsFromFly` ← `ImportEv |
| `fetchEvents` | `Data/EventMigrationLoader.swift:86` | Same function/gate as fetchGuests row above. |
| `fetchEvent` | `Data/EventMigrationLoader.swift:122` | Only reached inside the per-event detail fetch task group (lines 113-142), itself only pop |
| `fetchEvent` | `Data/EventMigrationLoader.swift:136` | Replenish-iteration duplicate of line 122 inside the same bounded task group; identical re |
| `fetchPantryItems` | `Data/PantryProfileMigrationLoader.swift:89` | Gated by a private-plane migration-scope check (lines 69-83: `guard let privateStore = ses |
| `fetchHouseholdAliases` | `Data/PantryProfileMigrationLoader.swift:99` | Same function/gate as fetchPantryItems row above; failure here is non-fatal (`aliases = [] |
| `fetchProfile` | `Data/PantryProfileMigrationLoader.swift:108` | Same function/gate as fetchPantryItems row above; failure here is non-fatal (`flyProfile = |
| `fetchIngredientPreferences` | `Data/PantryProfileMigrationLoader.swift:117` | Same function/gate as fetchPantryItems row above; failure here is non-fatal (`ingredientPr |
| `fetchRecipes` | `Data/RecipeMigrationLoader.swift:82` | IMPORTANT NUANCE — unlike every other loader in this slice, this one has NO account-type g |
| `fetchRecipeMetadata` | `Data/RecipeMigrationLoader.swift:92` | Same function/mechanism as the fetchRecipes row above (line 82); this call only executes a |
| `fetchRecipeImageBytes` | `Data/RecipeMigrationLoader.swift:153` | Same function/mechanism as the fetchRecipes row above; only reached inside the image-fetch |
| `fetchRecipeImageBytes` | `Data/RecipeMigrationLoader.swift:169` | Replenish-iteration duplicate of line 153 inside the same bounded task group; identical re |
| `fetchWeeks` | `Data/WeekMigrationLoader.swift:84` | Receipt-gated at this file's line 77 (`guard session.store.record(for: receiptID) == nil e |
| `fetchWeek` | `Data/WeekMigrationLoader.swift:113` | Same function/gate as fetchWeeks row above; only reached inside the per-week detail fetch  |
| `fetchWeek` | `Data/WeekMigrationLoader.swift:127` | Replenish-iteration duplicate of line 113 inside the same bounded task group; identical re |


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
