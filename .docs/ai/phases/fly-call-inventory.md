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

