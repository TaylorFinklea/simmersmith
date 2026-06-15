# SP-A Phase 0 — CloudKit Schema, recordName Policy & Indexes

> Container: **`iCloud.app.simmersmith.cloud`** (provisioned 2026-06-15).
> Parent: `cloudkit-sp-a-spec.md`. This is the **irreversible** layer — recordName
> policy, queryable indexes, the reference graph, and asset modeling can't be
> changed additively once data syncs (CloudKit schema is additive-only; recordName
> can never change without delete+recreate). Fields can be ADDED later; types and
> deletions cannot. Get this right; defer non-core fields.

## A. recordName policy (per record type — irreversible)

Three buckets (spec §6.1): **PK** = preserved legacy PK / random UUID for new rows
(needs query-before-create + resolver collapse for uniqueness); **DET** =
deterministic key (concurrent creates collapse to one record); **RAND+DEDUPE** =
random UUID + post-sync dedupe by a logical key.

| Record type | DB | Policy | recordName format | Why |
|---|---|---|---|---|
| HouseholdProfile | SHARED | PK | legacy `households.id` | CKShare root; stable identity |
| HouseholdSetting | SHARED | DET | `hset:<key>` | KV — concurrent set collapses |
| HouseholdTermAlias | SHARED | DET | `alias:<normalized_term>` | `UNIQUE(household_id,term)` |
| Week | SHARED | PK | legacy id / UUID | week_start NOT in recordName — a migrated UUID week and a new "week:date" can't be reconciled, so use query-before-create + §5.3 collapse |
| WeekMeal | SHARED | PK | legacy id / UUID | slot uniqueness via resolver repair, not recordName |
| WeekMealSide | SHARED | PK | legacy id / UUID | child of WeekMeal |
| **WeekMealIngredient** | SHARED | **PK** | legacy id / UUID | **NOT the content hash** (mutable → A1); hash is a queryable `matchKey` field |
| GroceryItem | SHARED | PK | legacy id / UUID | dedupe via §5.3 semantic keeper |
| FeedbackEntry | SHARED | PK | legacy id / UUID | appendable user feedback |
| WeekChangeBatch/Event | SHARED¹ | PK | legacy id / UUID | append-only audit (¹ prune or keep local — §9 Phase 2) |
| Recipe | SHARED | PK | legacy id / UUID | |
| RecipeIngredient/Step | SHARED | PK | legacy id / UUID | children of Recipe |
| **RecipeImage** | SHARED | DET | `rimg:<recipeID>` | enforces 1:1; CKAsset; concurrent regen = LWW on the asset |
| RecipeMemory | SHARED | PK | legacy id / UUID | many-per-recipe; optional CKAsset |
| Event | SHARED | PK | legacy id / UUID | |
| EventMeal/EventMealIngredient | SHARED | PK | legacy id / UUID | children of Event |
| **EventAttendee** | SHARED | DET | `<eventID>_<guestID>` | junction; re-add = upsert |
| EventGroceryItem | SHARED | PK | legacy id / UUID | `merged_into_*` pointers |
| **EventPantrySupplement** | SHARED | DET | `<eventID>_<stapleID>` | junction |
| Guest | SHARED | PK | legacy id / UUID | roster, outlives events |
| Staple | SHARED | PK | legacy id / UUID | pantry; recurring source-markers |
| BaseIngredient/IngredientVariation (household) | SHARED | PK | legacy id / UUID | |
| ProfileSetting | PRIVATE | DET | `pset:<key>` | per-user KV |
| **DietaryGoal** | PRIVATE | DET | `dietary_goal` | singleton per user |
| PreferenceSignal | PRIVATE | RAND+DEDUPE | UUID | dedupe `(signal_type,normalized_name)` post-sync |
| IngredientPreference | PRIVATE | RAND+DEDUPE | UUID | dedupe `(base_ingredient_id)`; client maintains `rank` |
| AssistantThread/Message | PRIVATE | PK | legacy id / UUID | transcript |
| BaseIngredient/Variation (approved/global) | PUBLIC | DET | `<normalized_name>` / `<kind>:<normalized_name>` | curator-written |
| NutritionItem/Match/RecipeTemplate/ManagedListItem | PUBLIC | DET | normalized key | curator-written |
| **MigrationReceipt** | PRIVATE | DET | `<householdID>`/`<userID>` | import-complete sentinel (spec §3.3) |

> **DET solves uniqueness, not merge.** Two offline devices writing the same DET
> recordName with different values still LWW one away (acceptable for KV/singletons).
> RAND+DEDUPE rows need the post-sync dedupe pass.

## B. Queryable fields / indexes (irreversible — adding later forces a reindex)

CloudKit only lets you `CKQuery` on fields explicitly marked QUERYABLE; the resolver
and catalog resolve depend on these. Mark at deploy:

| Record type | QUERYABLE | SORTABLE | Why |
|---|---|---|---|
| GroceryItem | `normalizedName`, `unit` | `createdAt` | dedupe + resolve CKQuery (§5.3, §8.2) |
| WeekMealIngredient | `matchKey`, `normalizedName` | — | aggregation match across devices |
| Week | `weekStart` | `weekStart` | query-before-create (dup-week) |
| BaseIngredient (PUBLIC+household) | `normalizedName` | — | resolve_ingredient cache-miss CKQuery (§8.2) |
| IngredientVariation (PUBLIC+household) | `normalizedName`, `baseIngredientRef` | — | variation lookup |
| NutritionItem | `normalizedName` | — | nutrition resolve |
| Recipe | `cuisine` | `createdAt` | library filters |
| HouseholdSetting / ProfileSetting | `key` | — | KV fetch |

All `CKReference` parent fields are implicitly queryable (children fetched by parent).
**Do NOT mark full bodies SEARCHABLE** (no full-text need; SEARCHABLE bloats the
index) — recipe/catalog search is client-side fetch-and-filter over the household's
own small set (spec §6 NO-FTS note).

## C. Reference graph + assets (irreversible structure)

- **CASCADE (`.deleteSelf` parent CKReference)** — deleting the parent sweeps
  children: Recipe→{Ingredient,Step,Image,Memory}, RecipeStep→substep,
  Week→{Meal,Side,Ingredient,Grocery,ChangeBatch,Feedback}, WeekMeal→{Side,Ingredient},
  Event→{Meal,Attendee,Grocery,Supplement}, EventMeal→Ingredient, NutritionItem→Match,
  AssistantThread→Message.
- **SET-NULL (plain `CKReference` or String key, client nulls on miss)** — `recipeRef`,
  `baseRecipeRef`, `parentStepRef`, `baseIngredientRef`, `variationRef`,
  `assignedGuestRef`, `mergedIntoGroceryItemRef`/`mergedIntoWeekRef`, `linkedWeekRef`,
  `attachedRecipeRef`. Self-ref subtlety: `baseRecipeRef` is SET-NULL, `parentStepRef`
  is CASCADE — do not swap (spec §6.3).
- **Cross-database keys are STRINGS, not CKReferences** (CKReference can't cross
  DBs): `AssistantThread.linkedWeekID` (PRIVATE→SHARED), all catalog keys into PUBLIC.
  Dangling = render "unavailable", never crash.
- **CKAsset (was LargeBinary, 1 MB CKRecord field cap)** — `RecipeImage.imageAsset`,
  `RecipeMemory.photoAsset`. Separate upload/download lifecycle; orphan-asset cleanup
  on `.deleteSelf`; UI tolerates a synced record whose asset hasn't downloaded.

## D. Deploy + verify (user-run — needs a CloudKit management token)

Schema authored as a `cktool`-importable CKDSL file (next: `phase0-schema.ckdb`).

```sh
# 1. Generate a management token: CloudKit Dashboard → container
#    iCloud.app.simmersmith.cloud → Tokens → new "CloudKit Management" token.
xcrun cktool save-token --type management        # paste the token

# 2. Validate (catches DSL errors without mutating), then import to DEVELOPMENT.
xcrun cktool validate-schema \
  --team-id <TEAM_ID> --container-id iCloud.app.simmersmith.cloud \
  --environment development --file .docs/ai/phases/phase0-schema.ckdb
xcrun cktool import-schema \
  --team-id <TEAM_ID> --container-id iCloud.app.simmersmith.cloud \
  --environment development --file .docs/ai/phases/phase0-schema.ckdb
```

**Phase 0 Verify:** `validate-schema` reports no errors; `import-schema` deploys to
Development with the QUERYABLE indexes from §B; the provisioning code (next) creates a
household zone + writes/reads `HouseholdProfile` round-trip. **Do NOT promote the
schema to Production until the recordName/index decisions above are final** — Production
schema is one-way.
