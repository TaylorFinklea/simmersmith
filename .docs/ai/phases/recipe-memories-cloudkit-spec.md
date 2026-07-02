# SP-D 990.4 — Recipe memories → CloudKit (schema spec, lead-gated)

Author: Fable 5 (arch-review follow-up, 2026-07-01). Status: schema DESIGNED; implementation is a senior follow-up (beads filed below). This is the **irreversible** deliverable — CloudKit schema is additive-only, so the record-type + field + ref decisions here are locked once deployed to Production (bead `pb8`).

## What exists

- **Fly model** (`app/models/recipe_memory.py`): `recipe_memories(id PK str, recipe_id FK→recipes ondelete=CASCADE, body Text default "", created_at, image_bytes LargeBinary NULL, mime_type str NULL)`. Per-cook log entries + one optional photo each (M15).
- **iOS** (all still Fly-wired, silently broken post-pivot): `AppState+Recipes.swift` memory methods (`apiClient`), `Features/Recipes/{RecipeMemoriesSection,MemoryComposeSheet,MemoryPhotoView}.swift`, entry in `RecipeDetailView.swift`.
- **CloudKit patterns to mirror**: the manifest `HouseholdRecordType` (scalars + refs, drives both `HouseholdRecordCodec` and the CKDSL) and `RecipeImageCodec` (CKAsset staged at a stable Caches path, `.deleteSelf` cascade parent, DET recordName with a type prefix, excluded from backup).

## Decision (irreversible — the lead-gated part)

**Two additive CloudKit record types**, splitting text from photo — mirroring the proven Recipe↔RecipeImage split rather than inventing "CKAsset on a manifest record":

### 1. `RecipeMemory` — in the manifest (`HouseholdRecordType`)

Add `case recipeMemory` to the enum + the three switches:

- `recordTypeName`: `"RecipeMemory"`
- `namePolicy`: `.pk` (memory's legacy surrogate UUID `id` verbatim — like `pantryItem`)
- `fields`: `[F("body", .string), F("createdAt", .date, sortable: true)]`
  - `sortable` because the section renders entries time-ordered. No `queryable` — the sync engine fetches the zone whole; filtering by recipe + sorting by `createdAt` is client-side (matches `weekMeal`).
  - `mimeType` is NOT here — it pairs with the photo, so it lives on the image record (below), matching Fly where `mime_type` sits beside `image_bytes`.
- `refs`: `[R("recipe", .cascadeParent, target: "Recipe")]`
  - CASCADE matches the Fly `ondelete=CASCADE`; a memory dies with its recipe. The engine's local `.deleteSelf` sweep handles the issuing device (same as every other cascade child).

**Consequence — memory TEXT is backed up.** Because `RecipeMemory` is in the manifest, `HouseholdBackup`/`HouseholdRecordCodec` snapshot its scalars automatically. That's correct and desirable: family cook-history is exactly what a backup should preserve. (Photos are not — see below, consistent with recipe images.)

### 2. `RecipeMemoryImage` — external codec, NOT in the manifest

A near-verbatim clone of `RecipeImageCodec`, one row per memory-with-photo (0-or-1 per memory):

- record type `"RecipeMemoryImage"`; recordName `"rmemimg:<memoryID>"` (DET, prefixed)
- fields: `mimeType` (string), `createdAt` (date), `imageAsset` (CKAsset, staged at a stable Caches path keyed by recordName — copy `RecipeImageCodec.assetStagingURL` verbatim)
- ref: `recipeMemory` — `CKRecord.Reference(action: .deleteSelf)` → the `RecipeMemory` record (cascade; deleting the memory removes its photo)
- **Excluded from backup** by construction (not a manifest type, exactly like `RecipeImage`). Rationale locked in the backup spec: images are excluded; memory photos follow that rule.

**Why two records, not an optional CKAsset field on `RecipeMemory`:** reuses a proven, tested pattern verbatim; keeps the manifest codec pure-scalar (no special-casing an asset field the generic codec would log as unexpected); keeps the backup include/exclude line clean (manifest = backed up, external image codecs = not). Cost is one extra client-side join by ref — identical to how `RecipeImage` already relates to `Recipe`.

## Migration of existing Fly memories

- Text rows migrate through the existing manifest-driven `HouseholdRecordMigration` path (mechanical snake_case derivation: `body`→`body`, `created_at`→`createdAt`, `recipe_id`→the `recipe` ref). Add `recipeMemory` to whatever drives the per-type migration loop — verify against how the other manifest types are enumerated there; do NOT hand-map.
- Photo bytes (`image_bytes`): best-effort, mirroring however recipe images were migrated (or skipped — backup already excludes images, so a lost photo on migration is non-fatal and recoverable by re-attaching). Confirm the recipe-image migration behavior and match it; do not invent a new path.
- Existing device's memories are read-through the migration loaders on first `ensureHouseholdSession`, receipt-gated like the other loaders.

## CKDSL + Production deploy

- `RecipeMemory` CKDSL is generated from the manifest (`ckdsl()` → appended to `phase0-schema.ckdb`) automatically once the enum case is added.
- `RecipeMemoryImage` is manifest-external → its type + `imageAsset`/`mimeType`/`createdAt` fields + `recipeMemory` ref must be hand-added to `phase0-schema.ckdb` the way `RecipeImage` was (find and mirror it).
- Both deploy to Production via the Dashboard under bead `pb8` (cktool can't deploy to prod; additive + irreversible). Dev auto-creates on first write, so on-device dev testing works before the prod deploy.

## Implementation beads (senior; file after this spec lands)

1. **Schema + codec + repository** (senior/M): add the `recipeMemory` manifest case (fields/refs/namePolicy above) + regen CKDSL; clone `RecipeMemoryImageCodec` from `RecipeImageCodec`; add a `RecipeMemoryRepository` (or fold into `RecipeRepository` — mirror how recipe images are read/written) with list-by-recipe / add / delete + optional-photo attach/read. Verify: `swift test --package-path SimmerSmithCloudKit` (new codec round-trip: scalars; asset attach→decode; cascade-delete-with-memory; backup captures body but not the photo record).
2. **App rewire** (senior/M): re-point `AppState` memory methods + `RecipeMemoriesSection`/`MemoryComposeSheet`/`MemoryPhotoView` off `apiClient` onto the repository; mirror how recipe images are surfaced. Verify: xcodebuild build.
3. **Migration** (senior/S): wire `recipeMemory` into the migration loop; photo best-effort per the recipe-image precedent. Verify: `swift test --package-path SimmerSmithCloudKit` migration round-trip test.
4. Production schema deploy rides bead `pb8` (human, Dashboard).

## Test invariants (spec-derived — specify exactly)

- Codec round-trips `RecipeMemory` scalars (body, createdAt) and the `recipe` cascade ref.
- `RecipeMemoryImage` round-trips through the CKAsset staging path; decode surfaces `assetNotDownloaded`/`emptyAsset` like `RecipeImageCodec`.
- Deleting a `Recipe` cascades to its `RecipeMemory` rows; deleting a `RecipeMemory` cascades to its `RecipeMemoryImage`.
- A `HouseholdBackup` snapshot INCLUDES memory `body`+`createdAt` and EXCLUDES the photo record.
