# SP-D 990.5 — Ingredients + nutrition catalog, CloudKit era (design spike)

Author: Fable 5 (arch-review follow-up, 2026-07-01). Status: IMPLEMENTATION DIRECTION,
re-grounded 2026-07-12 before the `990.5` loop. Key finding: **most of the CloudKit-era
ingredient architecture already exists**, but the original spike overstated both PUBLIC-reader
capability and migration readiness. This revision closes those gaps before implementation.

## What already exists (verified in code)

- **Record types** — `baseIngredient` + `ingredientVariation` are already in the `HouseholdRecordType` manifest (household zone), macro columns included (`calories`, `proteinG`, `carbsG`, `fatG`, `fiberG`, reference amount/unit). **No new schema needed for the catalog itself.**
- **PUBLIC catalog (read-only)** — `PublicCatalogReader` (SP-A Phase 6) resolves approved+active
  `BaseIngredient` / active `IngredientVariation` by exact `normalizedName`, projects macros,
  lists built-in templates, follows cursors, and degrades safely. Before this milestone it does
  **not** support browse/search, record-ID lookup, variation-by-base lookup, or CKReference
  projection; `CatalogRow` drops references. `990.5.1` adds those read-only capabilities. It
  remains a **frozen one-time seed** — the app NEVER writes PUBLIC.
- **Nutrition wiring** — `NutritionCalculator` already takes `PublicCatalogReader.macros(forNormalizedName:)` as its lookup closure. Catalog rows may be calories-only until the curator republishes with full macros (`hasFullMacros`) — that republish is bead `h2h`, not this spike.
- **Preferences** — ingredient preferences already moved to the private plane (`PreferenceRepository`, SP-C slice 5).

## The gaps this spike scopes

Everything in `AppState+Ingredients.swift` still calls `apiClient` (Fly), silently broken for migrated households:

1. **Household-zone CRUD is unbuilt.** `search/create/update/archive/merge` for base ingredients + variations, and `fetchBaseIngredientDetail` / `fetchIngredientVariations`, all hit Fly. The manifest types exist but no repository does household-zone CRUD over them.
2. **`resolveIngredient`** hits Fly (old AI-resolve).
3. **`saveIngredientNutritionMatch`** is explicitly deferred with a schema TODO (`AppState+Ingredients.swift:303`).
4. **Migration is not wired.** The manifest transform knows the two record types, but no
   production loader fetches/stages Fly ingredient rows. The original claim that they "already
   migrate as manifest types" was false. `990.5.1` must add a receipt-gated loader for
   household-owned base ingredients + variations; global approved rows stay in PUBLIC.

## Target architecture (three tiers — mostly already true)

- **PUBLIC catalog** — read-only shared approved reference data + macros. Via `PublicCatalogReader`. App never writes it.
- **Household zone** — the household's OWN base ingredients + variations + provisional rows (manifest `baseIngredient`/`ingredientVariation`). This is where all app-side creates/edits land, per the locked decision that **AI/MCP-resolved ingredients are household-private, not global-approved** (decisions.md 2026-06-02). "Merge into a global approved row" from the old Fly governance is GONE — the app can't write PUBLIC.
- **Private plane** — per-user preferences (done).

### Resolution precedence (CloudKit era, implementable form)

Adapt the grocery-resolution precedence (decisions.md 2026-03-30) to the serverless catalog:

1. A locked recipe variation short-circuits unchanged.
2. Establish the base/variation candidate: preserve an existing link, otherwise exact-match
   PUBLIC, then exact-match the household zone, then mint a household-only provisional row.
3. Once a base ID is known, apply an active `choiceMode == "preferred"` private-plane preference
   as an overlay: exact preferred-variation ID first, preferred-brand fallback second. Preserve
   the candidate when the preference is inactive, avoidance-mode, stale, or cannot resolve.

The earlier literal order ("preference before PUBLIC") is impossible because preferences are
keyed by base ID, not normalized name. Identifying the base first preserves the intended user
override without inventing a second preference index. New preference writes must persist the
human-readable `baseIngredientName`; the current empty-string write is a bug in this slice.

On-device matching = normalize + `normalizedName` equality against the cache/PUBLIC/household rows (both catalog types are `queryable` on `normalizedName`). An AI-assisted resolve (via `AIProviderKit`) is an OPTIONAL enhancement for fuzzy input, not required for parity — flag it as a follow-up, not part of the port.

## The one genuine lead-gated decision: `saveIngredientNutritionMatch`

The old feature let a user pin an ingredient→nutrition-item match; the TODO asks whether to add an `IngredientNutritionMatch` record type.

**Recommendation: do NOT add schema — verify-then-DROP.** The reason the manual match existed was to attach macros the catalog lacked. But the catalog now carries macros and `NutritionCalculator` already consumes them via `macroProjection`. So the manual match is very likely obsolete. Adding an irreversible CloudKit record type for a probably-dead feature is the wrong trade. Action for the impl bead: confirm `RecipeNutritionMatchView`'s actual reachability + value now that catalog macros feed `NutritionCalculator`; if the catalog covers the need, DELETE the feature (the Fly call + `RecipeNutritionMatchView` + `saveIngredientNutritionMatch`) rather than build new schema. Only if a real gap survives does an `IngredientNutritionMatch` type get designed — and that would come back to Lead as its own irreversible-schema decision (like `990.4`), not be slipped into the port.

## Migration

- Household-owned + provisional base/variation rows → household zone through a new receipt-gated
  loader, mirroring the typed recipe migration path. The existing list endpoint mixes global and
  household rows and caps at 200, so the migration must expose/fetch the complete owned set rather
  than assuming `limit=200` is exhaustive. Preserve legacy IDs and references; stamp the receipt
  only after base rows, variations, and the drain succeed.
- Approved-global rows: already in the frozen PUBLIC seed, or await the curator republish (`h2h`). Not app-migrated (app can't write PUBLIC).
- Nutrition matches: dropped per the decision above (or migrated only if the verify step finds the feature still needed).

## Impl beads (senior; filed under 990.5)

1. **Household-zone ingredient repositories + CRUD** (senior/L, implemented as bounded loop
   phases): extend the PUBLIC reader's identity/search/reference capabilities; build one combined
   `IngredientRepository` over the existing household manifest types; add CRUD + household-local
   merge (no global-approved mutation); compose PUBLIC/household/private reads at AppState; gate
   edit/archive/merge/add-variation controls to household-owned rows; route the grocery link picker
   entirely through repositories; add the receipt-gated Fly loader above. Mirror current repository,
   migration, and grocery-mutation patterns after reading them—do not invent signatures from this
   spec. New app-test source files require `xcodegen` and a committed pbxproj source entry.
2. **`resolveIngredient` on-device** (senior/M): first add the missing PUBLIC identity/reference
   reads and an additive public `IngredientResolution` initializer. Put the precedence policy in a
   pure SimmerSmithKit resolver with injected closures, then bind it to PUBLIC + household + private
   repositories in AppState. No JSON round-trip construction and no dependency cycle back from the
   CloudKit package into SimmerSmithKit.
3. **Nutrition-match verify-then-drop** (senior/S, START with the verify): confirm the manual match is obsolete under catalog macros; drop the feature + its UI, or escalate a schema decision to Lead. Verify: xcodebuild after removal; NutritionCalculator still resolves macros via the catalog.

Linkage: full-macro nutrition depends on the curator publishing macro columns (`h2h`); until then the catalog is calories-level and `hasFullMacros` is false — the client already handles both.
