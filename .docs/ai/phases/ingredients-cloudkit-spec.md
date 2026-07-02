# SP-D 990.5 — Ingredients + nutrition catalog, CloudKit era (design spike)

Author: Fable 5 (arch-review follow-up, 2026-07-01). Status: DESIGN DIRECTION (spike, spec-only). Key finding: **most of the CloudKit-era ingredient architecture already exists** — this spike documents the target, the real gaps, and one genuine lead-gated decision, then files impl beads.

## What already exists (verified in code)

- **Record types** — `baseIngredient` + `ingredientVariation` are already in the `HouseholdRecordType` manifest (household zone), macro columns included (`calories`, `proteinG`, `carbsG`, `fatG`, `fiberG`, reference amount/unit). **No new schema needed for the catalog itself.**
- **PUBLIC catalog (read-only)** — `PublicCatalogReader` (SP-A Phase 6) resolves approved+active `BaseIngredient` / active `IngredientVariation` by `normalizedName` (cache → PUBLIC CKQuery → nil), projects macros (`macroProjection`), lists built-in `RecipeTemplate`s, cursor-pages, degrades safely on error. It is a **frozen one-time seed** — the app NEVER writes PUBLIC (a curator/SP-E republishes out-of-band).
- **Nutrition wiring** — `NutritionCalculator` already takes `PublicCatalogReader.macros(forNormalizedName:)` as its lookup closure. Catalog rows may be calories-only until the curator republishes with full macros (`hasFullMacros`) — that republish is bead `h2h`, not this spike.
- **Preferences** — ingredient preferences already moved to the private plane (`PreferenceRepository`, SP-C slice 5).

## The gaps this spike scopes

Everything in `AppState+Ingredients.swift` still calls `apiClient` (Fly), silently broken for migrated households:

1. **Household-zone CRUD is unbuilt.** `search/create/update/archive/merge` for base ingredients + variations, and `fetchBaseIngredientDetail` / `fetchIngredientVariations`, all hit Fly. The manifest types exist but no repository does household-zone CRUD over them.
2. **`resolveIngredient`** hits Fly (old AI-resolve).
3. **`saveIngredientNutritionMatch`** is explicitly deferred with a schema TODO (`AppState+Ingredients.swift:303`).

## Target architecture (three tiers — mostly already true)

- **PUBLIC catalog** — read-only shared approved reference data + macros. Via `PublicCatalogReader`. App never writes it.
- **Household zone** — the household's OWN base ingredients + variations + provisional rows (manifest `baseIngredient`/`ingredientVariation`). This is where all app-side creates/edits land, per the locked decision that **AI/MCP-resolved ingredients are household-private, not global-approved** (decisions.md 2026-06-02). "Merge into a global approved row" from the old Fly governance is GONE — the app can't write PUBLIC.
- **Private plane** — per-user preferences (done).

### Resolution precedence (CloudKit era)

Adapt the grocery-resolution precedence (decisions.md 2026-03-30) to the serverless catalog:

1. Locked recipe variation (explicit user lock)
2. Household preferred variation / brand (private-plane preference)
3. `PublicCatalogReader.resolveBaseIngredient` / `resolveIngredientVariation` by `normalizedName`
4. Household-zone own/provisional row by `normalizedName`
5. Mint a household-only provisional row in the household zone (fallback)

On-device matching = normalize + `normalizedName` equality against the cache/PUBLIC/household rows (both catalog types are `queryable` on `normalizedName`). An AI-assisted resolve (via `AIProviderKit`) is an OPTIONAL enhancement for fuzzy input, not required for parity — flag it as a follow-up, not part of the port.

## The one genuine lead-gated decision: `saveIngredientNutritionMatch`

The old feature let a user pin an ingredient→nutrition-item match; the TODO asks whether to add an `IngredientNutritionMatch` record type.

**Recommendation: do NOT add schema — verify-then-DROP.** The reason the manual match existed was to attach macros the catalog lacked. But the catalog now carries macros and `NutritionCalculator` already consumes them via `macroProjection`. So the manual match is very likely obsolete. Adding an irreversible CloudKit record type for a probably-dead feature is the wrong trade. Action for the impl bead: confirm `RecipeNutritionMatchView`'s actual reachability + value now that catalog macros feed `NutritionCalculator`; if the catalog covers the need, DELETE the feature (the Fly call + `RecipeNutritionMatchView` + `saveIngredientNutritionMatch`) rather than build new schema. Only if a real gap survives does an `IngredientNutritionMatch` type get designed — and that would come back to Lead as its own irreversible-schema decision (like `990.4`), not be slipped into the port.

## Migration

- Household-owned + provisional base/variation rows → household zone via the manifest-driven migration (mechanical; `baseIngredient`/`ingredientVariation` already migrate as manifest types — verify they're in the migration loop).
- Approved-global rows: already in the frozen PUBLIC seed, or await the curator republish (`h2h`). Not app-migrated (app can't write PUBLIC).
- Nutrition matches: dropped per the decision above (or migrated only if the verify step finds the feature still needed).

## Impl beads (senior; filed under 990.5)

1. **Household-zone ingredient repositories + CRUD** (senior/L): `BaseIngredientRepository` + `IngredientVariationRepository` (or a combined `IngredientRepository`) over the existing manifest types — list/search-by-normalizedName/create/update/archive/merge on household-zone rows; mirror an existing repository (e.g. `PantryRepository`/`RecipeRepository`). Rewire `AppState+Ingredients` CRUD off `apiClient`. Note: `merge` is household-local only (no global-approved merge). Verify: `swift test --package-path SimmerSmithCloudKit` (repo CRUD + cascade) + xcodebuild.
2. **`resolveIngredient` on-device** (senior/M): implement the precedence chain above (locked → preference → PublicCatalog → household → mint-provisional). Verify: `swift test` (precedence unit tests over a fake catalog + household store).
3. **Nutrition-match verify-then-drop** (senior/S, START with the verify): confirm the manual match is obsolete under catalog macros; drop the feature + its UI, or escalate a schema decision to Lead. Verify: xcodebuild after removal; NutritionCalculator still resolves macros via the catalog.

Linkage: full-macro nutrition depends on the curator publishing macro columns (`h2h`); until then the catalog is calories-level and `hasFullMacros` is false — the client already handles both.
