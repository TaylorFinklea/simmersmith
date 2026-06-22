# SP-C — CloudKit cutover, slice 3: Weeks + Grocery

> Design spec. Approved scope 2026-06-20. Third cutover slice (after Recipes + Identity).
> Reuses the Recipes skeleton (HouseholdSession + per-feature repositories behind AppState + mapper +
> migration). SP-A already built the hard CloudKit pieces; this slice wires them + ports grocery regen.

## 0. Goal + scope (decided)

Cut the **Week planner + Grocery list** over to CloudKit. The meal-planning DATA works on-device;
the sticky-grocery field-merge (SP-A) is wired; the grocery list **auto-regenerates from meals on-device**
(porting the server algorithm — user's call); AI meal-generation/rebalance stays **coming-soon** (AI track).

**IN:** week create/fetch/navigate; meal add/swap/remove/edit/approve + sides; grocery add/edit/remove/
restore/check/store-label/dedupe; **client-side grocery regeneration**; the GroceryItem field-merge +
household-shared check-state; schema completion+deploy; one-time Fly→CloudKit migration of weeks+grocery;
un-gate the Week + Grocery tabs.

**OUT (→ AI track, stay coming-soon):** AI "generate my week", AI day-rebalance (`rebalanceDay`), any
AI meal drafting. Also OUT/dead: pricing/`RetailerPrice` (Kroger was dropped — fields migrate but no fetch),
`ExportRun`/reminders export (defer to a thin follow-on; the existing reminders-sync is already Fly-gated off).

## 1. What SP-A already built (wire, don't rebuild)
- **Manifest types** `.week`/`.weekMeal`/`.weekChangeBatch`/`.weekChangeEvent` (HouseholdRecordType) + their
  codec/migrate (manifest-driven). **GAP:** no `.weekMealSide` type — ADD it (new manifest case → schema deploy).
- **GroceryItem** has its own `GroceryCodec` (NOT a manifest type) — encode/decode GroceryItem↔CKRecord,
  preserving server change tags; all sticky fields present (isUserAdded/isUserRemoved/quantityOverride/
  unitOverride/notesOverride/isChecked/checkedBy/checkedAtClock/eventQuantity/storeLabel/sourceMeals/…).
- **Field-merge:** `GrocerySyncMerger` + `FieldMergeResolver` (sticky semantics: isUserRemoved monotonic-OR,
  isUserAdded sticky-OR, overrides prefer-set, check resolved as a unit by check.at clock, eventQuantity
  writer-owned). Already in the `HouseholdSession`'s `DispatchingMerger([Grocery, EventGrocery, Event])` seam,
  so conflict resolution is automatic on `engine.save` — the repository just saves.
- **WeekRepairAdapter:** repairSlots / reconcileSortOrder / collapseWeeks / pruneAudit (cross-record passes).
- **dedupe:** `ConflictRepair.dedupeGrocery` (tombstone losers) + `EventMergeAdapter.dedupeWeekGrocery`.
- **Normalization:** `GroceryNormalize` (normalize_name + UNIT_MAP, ported verbatim from the server).
- **Migrate transforms:** `migrateWeek`/`migrateWeekMeal`/`migrateGroceryItem` (MigrationTransforms.swift).
- **The Recipes-slice pattern** (RecipeRepository/RecipeRecordMapper/HouseholdSession/RecipeMigrationLoader)
  to mirror exactly.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `.weekMealSide` manifest type | new (HouseholdRecordType) | WeekMealSide record (sideId .pk; weekMeal cascadeParent; recipe setNull; name/notes/sortOrder/updatedAt) |
| `WeekRecordMapper` | new (SimmerSmithKit/CloudKit) | `WeekSnapshot ⇄ .week record (+ .weekMeal + .weekMealSide children)`, both directions. Mirror RecipeRecordMapper. |
| **`GroceryGenerator`** | new (SimmerSmithCloudKit/GroceryMerge) | **PORT the server regen** (§3) — the load-bearing piece. |
| `WeekRepository` | new (app Data/) | week+meal+side CRUD over the store; reassemble WeekSnapshot; reactive on storeRevision |
| `GroceryRepository` | new (app Data/) | grocery CRUD + check-state + regen (via GroceryGenerator) + dedupe (WeekRepairAdapter); GroceryCodec; engine merger handles conflicts |
| `AppState+Weeks`/`+Grocery` rewire | modify | DATA methods → repositories; AI methods (rebalanceDay, AI-gen) stay coming-soon/guarded; close the `apiClient.dedupeGrocery` leak |
| schema completion + deploy | cktool | complete `.week`/`.weekMeal`/`GroceryItem` fields (auto-created → incomplete, like recipes) + the new `.weekMealSide`; controller preps cktool, Taylor deploys |
| `WeekMigrationLoader` | new (app Data/) | one-time Fly pull of weeks+grocery → CloudKit (mirror RecipeMigrationLoader; receipt-gated; one-shot Fly auth) |
| un-gate Week + Grocery tabs | modify MainTabView | render WeekView/GroceryView (wired to repos) instead of ComingSoonView |

## 3. The grocery-regeneration port (load-bearing — get this faithful)
Port the server's grocery generation to Swift so the list rebuilds from a week's meals on-device.
**Read the authority first:** `app/services/grocery.py` — `regenerate_grocery` / `dedupe_week_grocery` /
the ingredient-aggregation. Match its behavior exactly. The algorithm (confirm against the Python):
1. For each non-removed meal in the week, take its recipe ingredients × `scaleMultiplier`/servings.
2. Normalize each ingredient name + unit via `GroceryNormalize` (already ported — reuse it).
3. Group by normalized name (+ compatible unit); sum quantities → `totalQuantity`; collect `sourceMeals`.
4. **Preserve sticky user state across a regen** (the whole point): keep `isUserAdded` rows even if no meal
   references them; keep `isUserRemoved` tombstones (don't resurrect); keep `quantityOverride`/`unitOverride`/
   `notesOverride`; keep `isChecked`/checkedAt/checkedBy; keep `eventQuantity` (event-merged portions);
   keep `storeLabel`. Only the auto-derived `totalQuantity`/`unit`/`sourceMeals`/`notes` get recomputed.
5. Result is a set of GroceryItem upserts (changed) + tombstones; write via the engine (the field-merge
   resolver handles any concurrent peer edit). Reuse `ConflictRepair.dedupeGrocery` for the dedupe pass.
> This is bounded, pure logic — unit-test it headlessly against fixtures (a 2-meal week with a shared
> ingredient → summed; a user-override survives regen; a tombstoned item stays removed; an event-quantity
> survives). High fidelity to the Python is the acceptance bar — diff behavior, don't approximate.

## 4. The week aggregate (read/write decomposition)
- **Read:** gather the `.week` record + its `.weekMeal` children (filter by `week` ref) + each meal's
  `.weekMealSide` children + the week's `GroceryItem` records (filter by `weekID` string field) →
  reassemble `WeekSnapshot` (meals[], groceryItems[], nutrition recomputed-or-nil per §5).
- **Write:** decompose WeekSnapshot → week record + meal records (diff add/remove like the recipe child-diff)
  + side records + grocery via the GroceryRepository. `saveWeekMeals` (batch meal replace) → diff against the
  store, save changed, delete removed (NOT cascade — explicit per-meal delete).
- **Navigation:** `currentWeek`/`browsedWeek` resolve by `weekStart` (the `.week` weekStart field is
  queryable+sortable in the manifest → can fetch-by-start, or scan the store's weeks).

## 5. Derived/deferred fields
- **Nutrition** (`MacroBreakdown`/`DailyNutrition`/`nutritionTotals`/meal `macros`): computed from ingredients
  × the catalog. **Defer** — recompute client-side later or nil for slice 3 (don't fabricate). The week/meal
  records don't store macros; the detail views show empty nutrition until a nutrition pass.
- **`RetailerPrice`** (pricing): Kroger dropped — migrate the field if present, no fetch; effectively empty.
- **`WeekSummary`** (the picker's count-only view): derive from the store (count meals/grocery per week).

## 6. Migration (one-time, weeks+grocery)
Mirror `RecipeMigrationLoader`: on the migration trigger (a one-shot Fly auth — the dormant sign-in methods
from the Identity slice), pull the user's weeks (`/api/weeks` + per-week detail) + grocery via the existing
apiClient, run `migrateWeek`/`migrateWeekMeal`/`migrateGroceryItem` → CloudKit, receipt-gated (`migrated:weeks`).
Decide the trigger UX in the plan (a one-time "import my weeks" action, since everyday Fly auth is gone).

## 7. AppState rewire + the coming-soon AI bits
- DATA methods (§ the map's DATA list) → delegate to WeekRepository/GroceryRepository, signatures preserved.
- AI methods (`rebalanceDay`, AI week-gen, the AI meal-create) → guarded/`ComingSoon` (mirror the Recipes AI
  gating) with `// AI TRACK` markers. The Week tab's "generate my week" affordance is disabled/hidden.
- **Close the leak:** `GroceryView` calls `appState.apiClient.dedupeGrocery(weekID:)` directly — route it
  through `appState.dedupeGrocery → GroceryRepository` (CloudKit dedupe via the adapter). Grep for other
  direct `apiClient.` calls in Week/Grocery views.

## 8. Verification
- **Headless:** `GroceryGenerator` fidelity tests (§3); `WeekRecordMapper` round-trip (week+meals+sides);
  the `.weekMealSide` manifest migrate test.
- **On-device (TestFlight):** (1) migrate real weeks+grocery in; (2) Week tab renders the planner, add/swap/
  remove/edit meals + sides persist + sync; (3) Grocery list: add/edit/remove/restore/check work, **check-state
  syncs across a 2nd engine** (the field-merge), regen-on-meal-change rebuilds correctly while preserving a
  user override + a checked item + a tombstone; (4) dedupe works; (5) Recipes still fine.

## 9. Risks
- **Regen fidelity** — the #1 risk: a port that diverges from the server's aggregation produces a wrong
  grocery list. Diff against `app/services/grocery.py`; test against fixtures; preserve ALL sticky fields.
- **Sticky-field loss on regen** — regen must NOT clobber user overrides/checks/tombstones/event-quantity
  (the entire point of the field-merge). The generator preserves them; the engine merger covers concurrent peers.
- **New `.weekMealSide` type** needs the dashboard "Deploy to Production" before on-device (like ManagedListItem).
- **Schema field-incompleteness** — `.week`/`.weekMeal`/`GroceryItem` prod schemas are auto-created→incomplete;
  complete+deploy them (the controller preps cktool, surfaces the one-click deploy).
- **Week aggregate size** — a week has many meals+grocery; the read reassembly must be efficient (store reads,
  not per-record fetches).
