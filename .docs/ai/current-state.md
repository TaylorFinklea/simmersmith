# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-06 — Build 61 (Week · bigger day pillar + past-day collapse)

User feedback on build 60: bump up the day pillar visual weight,
collapse past days by default to clear vertical real estate, allow
expanding any past day on tap.

`Features/Week/WeekView.swift`:
- New `@State expandedPastDays: Set<String>` keyed by
  `DayKey.server(date)` tracks which historical days the user has
  toggled open.
- New `isPastDay(_:)` helper using YYYY-MM-DD string comparison
  (timezone-safe) — true for any date strictly before today's
  local calendar day.
- `daySection` redesigned:
  - Pillar grew from 13pt name / 22pt numeral / 36pt wide
    → 17pt handwritten bold name / 38pt italic-serif numeral /
    54pt wide. Spine grew 2pt → 3pt on today.
  - Past days collapse to: pillar + summary line in italic
    Spectral ("3 meals · 2 done") + chevron-down toggle. Tap
    to expand → full slots render with smooth ease-in-out.
  - Today + future days always render slots (chevron not shown).
  - AI sparkle + MacroRing affordances move to today/future-only
    rows; past collapsed rows just show the chevron.
- New `pastDaySummary(meals:)` helper builds the collapsed-row
  one-liner: "no meals planned" / "1 meal" / "3 meals · 2 done"
  / "3 meals · all done".

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 60 → 61.

Pending IA builds (queue continues, all renumbered):
- Build 62: Forge (Recipes) — collapse 5 filter rows to one chip.
- Build 63: RecipeDetail.
- Build 64: Cooking.
- Build 65: Grocery.
- Build 66: Smith.

---

**Date**: 2026-05-06 — Build 60 (Fusion Week IA · multi-slot restored)

Build 59 was over-aggressive — it collapsed Week to one meal per day
and dropped the In-Season strip + snack affordances. User flagged
that the day rows must keep all configured slots (breakfast / lunch
/ dinner / etc.), the snack add affordance must come back, the
In-Season strip belongs at the top of the Week tab, and every empty
slot needs a quick-add. Build 60 walks the over-aggression back
while keeping the Fusion paper styling.

`Features/Week/WeekView.swift`:
- Body: FuHero → **InSeasonStrip** (back) → Tonight TodayMealCard
  → `daysSection` (multi-slot, restored from build 59's
  weekRosterSection).
- `daysSection` header: handwritten "the week" + ember underline
  (was `Text("This Week")` in subheadline). Weekly calorie pill
  retained but restyled (ember/risoGreen instead of orange/green
  filled capsule).
- `daySection`: leading 2pt ember spine on today (was full-row
  background tint), day pillar (handwritten 3-letter + italic
  serif numeral), AI per-day sparkle button restyled to ember
  outline. MacroRing per-day retained. Each day separated by
  `HandRule` (was nothing).
- `renderSlots(...style: .compact)` keeps the existing
  `CompactMealCard` per filled slot — already restyled in build
  58.
- `emptySlotButton`: paper tile with dashed-stroke rule border,
  Caveat slot label, italic-serif "plan a meal" placeholder,
  ember `+` on the right (was dark-card filled with system body
  font).
- `addSnackAffordance`: small ember Caveat "+ snack" affordance
  back (build 59 dropped it).
- The toolbar Menu (week picker, approve-all, jump-to-week) from
  build 59 stays — it's the right place for chrome that doesn't
  belong on the scroll surface.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 59 → 60.

Pending IA builds (queue continues):
- Build 61: Forge (Recipes) — collapse 5 filter rows to one chip row.
- Build 62: RecipeDetail — circular hero, dashed stats, my notes,
  in-pantry HandCheck on ingredients.
- Build 63: Cooking — ◆ AT THE FORGE top bar, riveted timer plate,
  Caveat ember CTAs.
- Build 64: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 65: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 59 (Fusion IA · Week roster restructure)

First of a multi-build IA pass after build 58 (which was skin-only)
landed. User flagged that the mockup spec implies real layout
changes, not just a palette + typography swap. Plan: ship one IA
restructure per build, in priority order, smoke-test between.

Build 59 covers Week:
- `Features/Week/WeekView.swift`:
  - Body simplified to: FuHero → Tonight TodayMealCard →
    `weekRosterSection`. The previous inline `weekPicker`,
    `InSeasonStrip`, `approveAllBar`, and `groceryBar` are
    removed from the scroll surface.
  - New `weekToolbarMenu` (top-leading) collapses week
    navigation (prev / next / jump-to-week list / snap-to-current)
    and the bulk approve-all action into a single Menu under the
    `simmer·smith` wordmark + chevron. The InSeasonStrip + grocery
    bar are dropped — InSeason discovery moves to a future build,
    Grocery is its own tab anyway.
  - New `weekRosterSection` renders one row per day (handwritten
    day name + italic-serif numeral pillar + featured-meal title
    + Caveat sub-line + ✓ done OR cook minutes on the right).
    Today gets a 2pt ember vertical spine on the left edge.
    `HandRule` separates rows. Tap a row → existing meal action
    sheet (or quick-add if the slot is empty).
  - New helpers: `featuredMeal(in:)` (prefers dinner →
    first-non-snack → first), `rosterSubline(for:)` (sides → notes
    first-line → empty), `rosterCookMinutes(for:)` (recipe prep+cook,
    nil if 0/0), `defaultSlotName()`, `approveAllMeals(_:)`.
- The old `daysSection` / `daySection` / `addSnackAffordance` /
  `rebalanceBanner` / `approveAllBar` / `groceryBar` / `weekPicker`
  helpers stay in the file but are no longer called. Left in place
  for now in case Savanne wants the macro ring / per-day calorie
  banner / approve-all bar back; will be deleted once dogfood
  confirms the sparser IA holds.

Verification: `xcodebuild build` succeeds. No backend, no schema,
no test changes. `project.yml` `CURRENT_PROJECT_VERSION` 58 → 59.

Pending IA builds (queued):
- Build 60: Forge (Recipes) — collapse 5 filter rows to one chip row.
- Build 61: RecipeDetail — circular hero, dashed stats, my notes,
  in-pantry HandCheck on ingredients.
- Build 62: Cooking — ◆ AT THE FORGE top bar, riveted timer plate,
  Caveat ember CTAs.
- Build 63: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 64: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 58 (Fusion redesign · The Smith's Notebook)

Visual redesign to direction E1 from Claude Design's mockup deck —
"Fusion · The Smith's Notebook (subtle Forge)". Linen-paper analog
as the base, ember (`#E8541C`) replacing amber as the accent, hot
iron treatment used sparingly on cooking + CTAs. Light-paper primary
following system color scheme; forge dark when iOS is in Dark Mode.
Native iOS Liquid Glass tab/nav bars and system buttons (Settings
gear, sheet ×, alert actions, etc.) preserved per user instruction —
the restyle applies to in-content surfaces only.

**Tokens** (`SimmerSmith/SimmerSmith/DesignSystem/Theme.swift`):
- Full rewrite. New `Color(light:dark:)` initializer wraps
  `UIColor { trait in … }` so every token resolves dynamically
  against `UITraitCollection.userInterfaceStyle`. iOS handles the
  light/dark switch; no `@Environment(\.colorScheme)` plumbing in
  views.
- New tokens: `paper`, `paperAlt`, `plate`, `ink`, `inkSoft`,
  `inkFaint`, `rule`, `ember`, `emberHot`, `bronze`, `risoBlue`,
  `risoGreen`, `risoYellow`. Stable public names (`primary`,
  `accent`, `surface`, `textPrimary`, etc.) are now type aliases
  pointing at the new tokens (`primary = ember`, `surface = paper`,
  etc.) — that's why the 59 consumer files didn't all need
  touching for the palette swap.
- `SMFont` adds Fusion-native helpers: `serifDisplay(_:)` (Instrument
  Serif Italic), `serifTitle(_:)` (Instrument Serif Regular),
  `bodySerif(_:)` / `bodySerifItalic(_:)` (Spectral),
  `handwritten(_:bold:)` (Caveat), `stencil(_:bold:)` (Oswald),
  `monoLabel(_:)` (system .monospaced uppercase). Existing
  semantic aliases (`display`, `headline`, `subheadline`, `body`,
  `caption`, `label`) are bound to these new families.
- `SMRadius` flattened: 2/4/8/12 (was 8/12/16/20). Fusion is
  rectilinear paper-on-paper.
- **Fonts bundled** — 6 .ttf files (~1.3MB) at
  `SimmerSmith/SimmerSmith/Resources/Fonts/` (Instrument Serif
  Regular+Italic static, Spectral Regular+Italic static, Caveat
  variable, Oswald variable), registered via `UIAppFonts` in
  `Info.plist`, picked up automatically by xcodegen's recursive
  source walk. OFL attribution at `Resources/Fonts/LICENSE.txt`.
  PostScript names verified via `fc-scan`; the Caveat bold path
  uses `CaveatRoman-Bold` (the variable font ships its bold
  instance under that PostScript group, not as `Caveat-Bold`).

**Drawing primitives** (new
`SimmerSmith/SimmerSmith/DesignSystem/Components/FusionPrimitives.swift`,
~470L):
- `HandRule`, `HandUnderline`, `HandCheck` — squiggle Path views
  for paper-style dividers, hero underlines, and ingredient ticks.
- `Rivet`, `RivetCorners`, `.rivetCorners(...)` — riveted brass /
  iron corners on hero cards.
- `PaperGrain`, `PaperBackground`, `.paperBackground()` — linen
  dot-noise overlay; the standard root background of every Fusion
  screen body.
- `FuMark` — anvil + ember brand mark drawn in SwiftUI Canvas (no
  static asset). Themes with the system; ember glows in Dark Mode.
- `FuWordmark` — `simmer·smith` in Instrument Serif italic with
  ember dot, replaces the static `BrandLockup.imageset`.
- `FuHero` — in-content hero header (mono eyebrow + 38pt italic
  serif title + ember hand-drawn underline). System nav bar stays
  Liquid Glass on top; the FuHero is the visual anchor inside the
  scroll content.
- `FuPlate`, `FuIndexCard`, `FuWashiTape` — riveted forge plate,
  paper index card with optional washi-tape strip, washi tape
  primitive.
- `FuEmberCTA`, `FuOutlinedPill`, `FuEyebrow`, `FuRecipeNumber` —
  Caveat ember CTA, outlined-Caveat pill, mono uppercase eyebrow,
  `№003` recipe number badge.

**Components** (14 files in `DesignSystem/Components/`, public APIs
unchanged): paper backgrounds, 0.5pt rule borders, rectangular (not
rounded) edges, italic-serif titles, Caveat sub-lines, ember accents.
- `SMCard`: paperAlt fill, 0.5pt rule, soft shadow in light only.
- `CuisinePill`: outlined Caveat (no fill), slight rotation.
- `TimeBadge`: italic-serif numeral + Caveat unit.
- `RecipeCard` / `CompactRecipeCard`: paperAlt tile, mono `№NNN`
  badge, italic-serif title; alternating slight rotations on the
  grid version.
- `HeroRecipeCard`: large italic-serif title, hand-drawn ember
  underline.
- `RecipeListRow`: italic-serif title, Caveat meta, ember sparkle
  + ember heart (replacing the AI-purple sparkle).
- `MacroRing`: ink/ember/risoGreen/bronze macro accents (was
  primary/aiPurple/orange).
- `CompactMealCard`: paperAlt tile, italic-serif name, Caveat slot
  label; sides chips become outlined.
- `TodayMealCard`: index-card paper treatment with washi-tape +
  rivet corners + ◆ AT THE FORGE eyebrow + "fire up →" Caveat ember.
- `MealSlotRow`: Caveat slot, italic-serif name, italic placeholder.
- `DayCard`: italic-serif day name + ember underline; rows separated
  by hand rules (was solid divider).
- `AIFloatingButton`: solid ember disk with ember glow.

**Feature views** (in-content only — chrome stays native):
- `WeekView` (1381L): "this week" `FuHero` at top of scroll +
  `paperBackground()`. Today card + day cards inherit the new
  component look automatically.
- `RecipesView` (1071L): "the **forge**" hero with ember accent on
  "forge"; nav title flipped to "Forge"; `paperBackground()`.
- `RecipeDetailView` (1267L): `paperBackground()`; loading + empty
  states get italic-serif copy + ember tint. Removed
  `toolbarBackground(SMColor.surface, …)` so Liquid Glass takes
  over the nav bar.
- `GroceryView` + `PantryView`: `paperBackground()`; native List
  + Liquid Glass nav unchanged.
- `CookingModeView` (362L): forced forge dark regardless of system
  mode (`.preferredColorScheme(.dark)`), lamp-lit iron background
  + ember radial glow seeping from the bottom, **96pt Oswald
  stencil step number with ember glow** as the marquee element,
  Spectral 26pt italic instruction text.
- `AssistantView` (502L): nav title flipped to "Smith"; empty
  state replaced with `FuMark` + Caveat ember "at the anvil"
  eyebrow + italic-serif "draft a meal." headline.
- `EventsView` + `EventDetailView`: `paperBackground()`; removed
  `toolbarBackground(SMColor.surface, …)` so Liquid Glass takes
  over.
- `SignInView`: linen paper with ember radial glow from below,
  `FuMark` + `FuWordmark` brand lockup, "every recipe forged by
  hand." Caveat ember eyebrow, italic-serif "Cook with fire." hero,
  Spectral italic body copy, hand-drawn ember underline. Native
  Sign In with Apple + Google buttons retained.
- `SettingsView` (1358L): kept fully native `Form` per user
  instruction; `paperBackground()` swap. Settings gear stays
  native.
- `SubstitutionSheetView`: removed `toolbarBackground(...)`.

**Tab bar** (`MainTabView`):
- Recipes → **Forge**, Assistant → **Smith**. Other labels
  unchanged (Week / Grocery / Events).
- `.tint(SMColor.primary)` → `.tint(SMColor.ember)` (same value,
  clearer call site).
- Native SF Symbol icons preserved (calendar / book / cart /
  party.popper / sparkles).
- Liquid Glass tab bar chrome untouched per user instruction.

**Brand assets**:
- `AccentColor.colorset/Contents.json`: pointed at ember
  (`#E8541C`) so any unstyled native control inherits the new
  accent.
- `BrandMark.imageset` and `BrandLockup.imageset` retained on disk
  for legacy reference; onboarding now renders the wordmark in
  code via `FuWordmark`.

**Project / verification**:
- `SimmerSmith/project.yml`: `CURRENT_PROJECT_VERSION` 57 → 58.
- 325 backend tests pass (`pytest -q`).
- 26 SimmerSmithKit tests pass (`swift test`).
- `SimmerSmithTests` unit suite passes.
- `xcodebuild build` succeeds.
- 6 `SimmerSmithUITests` failures are pre-existing — they expect a
  ConnectionSetup form that only shows for signed-out users; the
  simulator has persisted Apple/Google sign-in. Not a regression.
- `testTabBarShowsAllMainTabs` passes after the Forge/Smith
  relabel.

**Out of scope** (explicit deferrals):
- App icon redesign (HANDOFF flagged the existing mark-only icon
  as off-center).
- Custom MealArt vector illustrations per cuisine — recipe photos
  / gradient placeholders retained.
- Heavy Forge variant (E2).
- Animation polish, transitions, motion.
- Localization audit for the new lowercase brand voice.

**Font sourcing — resolved**:
- User authorized fetching from `github.com/google/fonts`. Six
  .ttf files pulled directly from the official Google Fonts
  upstream repository (OFL-licensed, AGPL-compatible) and bundled
  into the app at `SimmerSmith/SimmerSmith/Resources/Fonts/`.
  Total bundle weight: ~1.3MB. Caveat + Oswald shipped as the
  upstream variable fonts; Instrument Serif + Spectral as static
  Regular + Italic instances.

---

**Date**: 2026-05-06 — Build 57 ship (quick meal tag + freezer pantry kind)

Two pieces of dogfood feedback bundled into one ship: a `quick`
meal tag for ≤30-minute weeknight recipes, and a freezer kind on
pantry items with leftover-from-meal capture + a "Use Soon"
staleness filter. One build, single dogfood pass.

**Backend** (one migration: `staples.frozen_at TIMESTAMPTZ NULL`):
- `app/models/profile.py`: `Staple.frozen_at: datetime | None`.
  NULL = regular pantry item; set = freezer item placed at this
  timestamp. No new model; the discriminator is the timestamp
  itself.
- `alembic/versions/20260506_0036_staple_frozen_at.py`: trivial
  `add_column` migration. No backfill — every existing row is
  implicitly non-frozen.
- `app/schemas/profile.py`: `PantryItemOut`/`AddRequest`/`PatchRequest`
  carry `frozen_at`. PATCH gets a `clear_frozen_at: bool` flag for
  un-freeze.
- `app/api/pantry.py`: `_payload` emits `frozen_at`. Add route now
  forwards `payload.categories` to the service (was a build-56 bug
  — categories were dropped when only the list field was sent on
  POST). Add route also forwards `frozen_at`.
- `app/services/pantry.py`: `add_pantry_item` / `update_pantry_item`
  accept `frozen_at`. Update path honors `clear_frozen_at` to wipe.
- `app/services/recipe_drafting.py`: prompt now instructs the AI
  to add `"quick"` to `tags` when `prep_minutes + cook_minutes ≤
  30`. Refine prompt re-evaluates after a tweak so a user request
  like "scale this down" can either earn or drop the tag.
- New tests: `tests/test_pantry.py` round-trips `frozen_at` +
  `clear_frozen_at`. `tests/test_recipe_quick_tag.py` verifies the
  prompt carries the rule, refine re-evaluates, and the API
  preserves the tag end-to-end. **325/325 pass** (was 321).

**iOS**:
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift`: `PantryItem`
  gains `frozenAt: Date?` + helpers (`isFrozen`,
  `daysSinceFrozen`, `isStaleFreezerItem` ≥30d).
- API client `PantryItemAddBody.frozenAt`,
  `PantryItemPatchBody.frozenAt` + `clearFrozenAt` (the explicit
  un-freeze flag).
- `Features/Recipes/RecipesView.swift`: new "Quick (≤30 min)"
  filter pill alongside difficulty + cleanup. Predicate
  `tags.contains("quick") || (prep+cook ≤ 30)` with a `0+0=0`
  guard so untimed recipes don't false-positive.
- `Features/Week/RecipePickerSheet.swift`: same Quick chip on the
  week meal picker so a user picking dinner at 6pm can narrow
  fast.
- `Features/Grocery/PantryItemEditorSheet.swift`: new "Freezer
  item" toggle + date picker for `frozenAt`. Toggling on
  pre-selects the Freezer category chip. PATCH path emits the
  field that changed (`frozenAt` or `clearFrozenAt`).
- `Features/Grocery/PantryView.swift`: segmented filter (All /
  Pantry / Freezer / Use Soon). Freezer view sorts FIFO. Use Soon
  surfaces items frozen ≥30 days. Inline orange "Use soon" badge
  + a "Frozen Nd ago" line on every freezer row.
- `Features/Week/SaveLeftoversToFreezerSheet.swift` (new): small
  form opened from the meal action sheet ("Save leftovers to
  freezer"). Prefills `<recipe name> leftovers`, today's date,
  saves a freezer pantry item with `categories=["Freezer"]`.
  Always available — no gating on a mark-cooked flow.

**Build bump**: 56 → 57.

**Out of scope (deferred):** `WeekMeal.status` / mark-cooked flow,
quantity-on-hand for freezer items, per-item stale window
override, home-screen / assistant nudge for stale items, freezer
inventory in the AI meal planner.

### Earlier session (build 56 — pantry UX upgrade)

**Date**: 2026-05-05 — Build 56 ship (pantry UX: ingredient autocomplete + multi-select categories)

**Build 56** addresses dogfood feedback on the pantry editor: too
much free-text typing, no awareness of the existing ingredient
catalog, single-string category that didn't match real-world
multi-section items.

**Backend** (no migration — comma-joined storage on existing
`Staple.category` column):
- `app/services/pantry.py`: new `serialize_categories` and
  `parse_categories` helpers handle the round-trip between the
  list-shaped API surface and the legacy single-string column.
  `add_pantry_item` / `update_pantry_item` accept a `categories`
  list (wins over the legacy `category` string).
- `app/schemas/profile.py`: `PantryItemOut` now carries both
  `category: str` (back-compat) and `categories: list[str]`.
  `PantryItemAddRequest` + `PantryItemPatchRequest` accept the
  new list field.
- `app/api/pantry.py`: `_payload` derives `categories` from the
  stored string for every read.
- New test in `tests/test_pantry.py` round-trips the list +
  exercises the helpers' edge cases. 321/321 pass.
- `app/api/weeks.py`: imported missing `Settings` alongside
  `get_settings` (silent pyright fix; runtime worked because of
  `from __future__ import annotations`).

**iOS**:
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift`: `PantryItem`
  gains `categories: [String]` + a `displayCategories` accessor
  that falls back to splitting the legacy single string. Custom
  decoder handles older cached payloads.
- API client `PantryItemAddBody` + `PantryItemPatchBody` carry the
  new `categories` field.
- `PantryItemEditorSheet`:
  - Name field now searches the household ingredient catalog after
    300 ms debounce. Tapping a suggestion prefills name + auto-
    selects the catalog row's category. Free-text input still
    works for one-off pantry items.
  - Replaced the single-line category field with a chip multi-
    picker. Defaults: Produce / Dairy / Meat / Seafood / Pantry /
    Freezer / Beverages / Condiments / Baking / Snacks / Spices.
    Merged with categories already in use across the household so
    custom values stick around. Inline "Add custom" affordance.

**Build bump**: 55 → 56. Backend has no migration — pure column
serialization change.

### Earlier session (build 55 / Fly v80 — multi-select + FAB removal)

**Build 55** absorbs build-54 dogfood UX feedback (FAB overlapping
recipe rows, no bulk-delete) AND lands the originally-planned
review-first refactor: web search, recipe variation, and recipe
companion drafts now route through `RecipeDraftReviewSheet` so they
inherit the refine loop introduced in build 53.

**iOS**:
- `Features/Recipes/RecipesView.swift`:
  - Removed the `AIFloatingButton` overlay; "AI suggestion" moved
    into the existing top-right `+` menu (next to "New recipe").
  - New "Select recipes" item in the same menu enters multi-select
    mode. Toolbar swaps to "Done" + "N selected"; rows render with
    a checkbox; bulk-action bar pinned to the bottom shows
    "Delete N" with a destructive confirmation dialog.
  - Web-search results now route through `RecipeDraftReviewSheet`
    (refine + edit before save).
- `Features/Recipes/RecipeDetailView.swift`: AI variation drafts +
  companion drafts both route through `RecipeDraftReviewSheet`.
  Same refine loop the side / event-meal / quick-add flows have.
- Bulk delete reuses `appState.deleteRecipe` per row + surfaces
  partial failures via `lastErrorMessage`. Selection persists for
  the failed entries so the user can retry.

**Build bump**: 54 → 55. No backend changes (pure iOS surfaces).

**Pause for dogfood after build 55.** Build 56 candidates:
- Assistant `recipe_draft` envelope routing through review sheet.
- More bulk operations (favorite, archive, move to week).
- Polish from 55 dogfood findings.

### Earlier session (build 54 / Fly v80 — M29 dogfood fixes + AI cleanup filters)

**Build 54** addresses TestFlight 53 feedback (intermittent "invalid
JSON" on AI gen, slow Save, no way to find AI-generated slop, stuck
Delete) and adds the AI cleanup-filter UI. Originally planned scope
(routing existing review-first surfaces through `RecipeDraftReviewSheet`)
deferred to build 55 since they don't auto-save anyway — feedback
items took priority.

**Backend**:
- `app/services/recipe_drafting.py`: new `_provider_call_with_json_retry`
  helper. Both `generate_recipe_draft_for_dish` and
  `refine_recipe_draft` now retry once on `JSONDecodeError` with a
  tightened "Return ONLY the JSON object — no markdown fences"
  reminder before raising 502. Catches the dogfood case where the
  LLM occasionally wraps its response in fences.
- New test `test_refine_route_retries_invalid_json_once` in
  `tests/test_recipe_draft_refine.py`. 320/320 pass.

**iOS**:
- `AppState+Recipes.swift`: `saveRecipe` no longer awaits the
  metadata refresh — that's now a fire-and-forget Task. Halves
  the perceived latency of the Save tap. `deleteRecipe` now pulls
  a fresh server list right after the 204 lands so a stale local
  cache can't show a deleted recipe.
- `RecipeDraftReviewSheet.swift`: tap-to-Save dismisses the sheet
  IMMEDIATELY and runs the save chain in a follow-up Task. Errors
  surface via `appState.lastErrorMessage`.
- `DesignSystem/Components/RecipeListRow.swift`: AI badge
  (sparkles, purple) on rows whose `source` starts with `ai`.
- `Features/Recipes/RecipesView.swift`: new `cleanupFilterPills`
  row with 4 chips: All / AI-generated / Never used / Unused 30+
  days. When active, swaps editorial sections for a flat list
  sorted least-recently-used first. New `RecipeCleanupFilter` enum.

**Build bump**: 53 → 54.

**Pause for dogfood after build 54.** Build 55 will route the
remaining review-first surfaces (web search, recipe variation,
recipe companion) through `RecipeDraftReviewSheet` to give them
the refine loop, plus assistant `recipe_draft` envelope refactor
+ polish from 54 dogfood findings.

### Earlier session (build 53 / Fly v79 — M29 review-before-commit + side AI gen)

**Build 53** opens the M29 milestone (3-build cadence). Solves the
"AI slop" problem: pre-build-53 the event-meal AI gen and quick-add
AI gen both auto-saved every draft into the recipes library, so a
user iterating 3-5 times to get the right recipe ended up with 3-5
abandoned recipes. Build 53 introduces a single review funnel +
adds the previously-missing side-recipe AI generation.

**Backend**:
- New `app/services/recipe_drafting.py` — `generate_recipe_draft_for_dish`
  (generic per-dish helper, used by event + side routes) and
  `refine_recipe_draft` (the engine of the iOS refine loop). Reuses
  M27 `unit_system_directive` + assistant_ai's `extract_json_object`
  + `run_direct_provider`. **No DB writes anywhere in the loop.**
- New `POST /api/recipes/draft/refine` route in `app/api/recipes.py`.
  Body: `{draft, prompt, context_hint}` → returns refined `RecipePayload`.
- New `POST /api/weeks/{w}/meals/{m}/sides/{s}/ai-recipe` in
  `app/api/weeks.py`. Returns a draft scaled to the parent meal's
  servings.
- `event_ai.generate_recipe_for_meal` slimmed to a thin wrapper
  around the shared helper so the per-dish event flow goes through
  the same plumbing.
- Tests: `tests/test_recipe_draft_refine.py` (3 cases) +
  `tests/test_side_ai_recipe.py` (2 cases). Existing event-recipe
  test patched to also stub `recipe_drafting.run_direct_provider`.
  321/321 backend tests pass.

**iOS**:
- New `Features/Recipes/RecipeDraftReviewSheet.swift` — the single
  funnel. Init takes `initialDraft` + `refineContextHint` + `onSave`
  + optional `onDiscard`. Surfaces a draft summary, a "Refine with
  AI" prompt+button (with iteration counter footer "refined N
  times · nothing saved yet"), an "Edit by hand" path that opens
  `RecipeEditorView`, and Save/Discard buttons. Save is the ONLY
  persistence path.
- `EventMealEditorSheet.swift` — `generateRecipeWithAI` no longer
  auto-saves. Sets a `pendingDraft` state and presents the review
  sheet; `onSave` runs the existing PATCH-event-meal link.
- `AIRecipeCreateSheet.swift` (Week quick-add AI) — rewritten as a
  thin generation shell that hands off to the review sheet. Save
  button removed; the review sheet's onSave forwards to the
  caller's `onSaved`.
- `MealSidesSheet.swift` (the inline `SideEditorSheet`) — new
  "Generate recipe with AI" section in the side editor. Hint
  TextField + button → calls
  `apiClient.generateSideRecipeDraft` → review sheet → on save,
  PATCHes the side's `recipeId`. Closes the M26 follow-up gap.
- New API client methods: `generateSideRecipeDraft`,
  `refineRecipeDraft`. New AppState helper `refineRecipeDraft`.
- `RecipeDraft` declared `Identifiable` (id derived from recipeId
  ?? name) so `.sheet(item:)` works for in-flight drafts.

**Build bump**: 52 → 53.

**Pause for dogfood after build 53.** Build 54 will route the
existing review-first surfaces (web search, variation drafts,
companion drafts) through `RecipeDraftReviewSheet` to give them
the refine loop. Build 55 wires the assistant `recipe_draft`
envelope through the same funnel + polish from 53/54 dogfood.

### Earlier session (build 52 / Fly v78 — M28 phase 2 event pantry supplements)

**Build 52** completes the M28 pantry feature. Phase 1 (build 51)
added the recurring fold-in. Phase 2 lets events request
supplemental quantities of pantry items beyond normal household
stock — e.g. "we usually keep 5 dozen eggs, but this party needs
100 extra."

- `alembic/versions/20260505_0035_event_pantry_supplements.py`:
  new `event_pantry_supplements` table with FK cascades from both
  `events` and `staples`. Unique on `(event_id, pantry_item_id)`
  so one supplement per pantry item per event.
- `EventPantrySupplement` model + `Event.pantry_supplements`
  relationship.
- `app/services/event_supplements.py` (new): CRUD by id with the
  duplicate-by-pantry-item guard.
- `app/services/event_grocery.py:_aggregate_event_rows` extended:
  bypasses the staple filter for supplements (the whole point —
  the user explicitly said "extra of this pantry item"),
  attributes via `source_meals="pantry-supplement:<id>"`.
- `app/api/events.py`: GET/POST/PATCH/DELETE supplement routes.
  Each mutation re-runs `regenerate_event_grocery` +
  `apply_auto_merge_policy` so the linked week's grocery list
  reflects the change as `event_quantity`.
- `EventOut` schema + presenter expose `pantry_supplements`.
- 6 new backend tests in `tests/test_event_supplements.py`. 314
  total backend tests pass.

**iOS**:
- `EventPantrySupplement` model + `Event.pantrySupplements`.
- 3 new API client methods (add/patch/delete) returning the
  refreshed Event.
- AppState helpers in `AppState+Events.swift`.
- `EventDetailView` gets a "Pantry supplements" section between
  Menu and Guests-bringing.
- `EventPantrySupplementSheet` for add/edit/delete; pantry item
  picker excludes items that already have a supplement on the
  event.

**End-to-end behavior**: user has Eggs in pantry with a 60-ct
weekly recurring. Adds an event "Easter Brunch" with a +100 eggs
supplement. The week's grocery list shows a single Eggs row:
`total_quantity = 60` (recurring restock) + `event_quantity =
100` (supplement) — user sees `160 ct` total with a "+100 from
Easter Brunch" attribution.

**Build bump**: 51 → 52.

### Earlier session (build 51 / Fly v77 — M28 phase 1 pantry extension)

**Build 51** extends the existing `staples` table into a full pantry
concept. Pre-M28, staples already filtered from meal-driven grocery
aggregation ("we always have eggs, don't add them to grocery just
because a meal needs them"). M28 adds two more capabilities:

- **Typical purchase quantity**: informational metadata on how the
  household buys an item (e.g. "50 lb bag of flour"). Surfaced on
  the pantry editor; doesn't change grocery quantities.
- **Recurring auto-add**: each pantry item can carry an optional
  cadence (`weekly` / `biweekly` / `monthly`) + quantity + unit.
  When set, `apply_pantry_recurrings` folds it into the week's
  grocery list as a `user_added` row. The function is idempotent
  (matches by `pantry:recurring:<id>` source marker) and respects
  the cadence gap via `last_applied_at`. It also runs at the tail
  of `regenerate_grocery_for_week` so any regen brings recurrings
  current.

**Backend**:
- `alembic/versions/20260505_0034_pantry_columns.py` adds 7
  columns to `staples`: `typical_quantity`, `typical_unit`,
  `recurring_quantity`, `recurring_unit`, `recurring_cadence`,
  `category`, `last_applied_at`.
- `app/models/profile.py:Staple` gets the new fields + a docstring
  rebrand explaining the pantry vs. pure-staple split.
- `app/services/pantry.py` (new): `add_pantry_item`,
  `update_pantry_item`, `delete_pantry_item`,
  `apply_pantry_recurrings`, `_is_due` cadence resolver.
- `app/api/pantry.py` (new): GET/POST/PATCH/DELETE `/api/pantry`
  + `POST /api/pantry/apply/{week_id}`. PATCH-by-id flow keeps
  recurring metadata across partial saves; the legacy
  `PUT /api/profile` staple flow still works for simple edits.
- `app/services/grocery.py:regenerate_grocery_for_week` now calls
  `apply_pantry_recurrings` after smart-merge.
- Tests: `tests/test_pantry.py` (6 cases — recurring lands,
  idempotent, cadence gap, regen integration, partial update,
  staple-filter regression). 308/308 backend pass.

**iOS**:
- `PantryItem` model in SimmerSmithKit + 5 API client methods.
- `AppState.pantryItems` state + `AppState+Pantry.swift` helpers
  (load/add/patch/delete + applyToCurrentWeek).
- `Features/Grocery/PantryView.swift` reachable from Grocery →
  ⋯ menu → "Pantry". Lists items with cadence badges, supports
  swipe-to-delete + manual "Apply recurrings to this week"
  button.
- `Features/Grocery/PantryItemEditorSheet.swift` — name +
  category + active toggle + typical-purchase qty/unit +
  recurring cadence picker + recurring qty/unit + notes.

**Build bump**: 50 → 51.

**Out of scope for phase 1, follows in phase 2**: event
supplemental override (e.g. event needs 100 eggs, supplement the
recurring pantry stock by N for that event).

### Earlier session (build 50 / Fly v76 — M27 unit-system localization)

**Build 50** adds a per-user `unit_system` profile setting (`us` |
`metric`, default `us`) that constrains every recipe-producing AI
prompt to one unit system. Drift was unconstrained before — the AI
mixed cups + grams in the same recipe.

- `app/services/ai.py` — `unit_system()` + `unit_system_directive()`
  helpers. The directive is a top-of-prompt instruction
  (`UNIT SYSTEM — US CUSTOMARY ONLY` / `UNIT SYSTEM — METRIC ONLY`)
  that enumerates the allowed units (cups/tbsp/oz/lb/°F vs g/ml/°C)
  and tells the AI to convert from imported sources before
  responding.
- Injected into the high-traffic recipe surfaces:
  - `week_planner._build_system_prompt` (whole-week plan)
  - `event_ai._build_prompt` (whole-event menu)
  - `event_ai._build_per_dish_prompt` (M26 Phase 4 per-dish)
  - `recipe_search_ai._build_input` (find a recipe via web search)
  - `substitution_ai._build_prompt`
  - `assistant_ai.build_planning_system_prompt` + `build_assistant_prompt`
- `app/services/bootstrap.py:DEFAULT_PROFILE_SETTINGS` adds
  `unit_system: "us"` so every new household starts on US customary
  by default; legacy users without the row inherit `"us"`.
- iOS: `AppState.unitSystemDraft` + `saveUnitSystem` / `syncUnitSystemDraft`
  helpers (M17 image-provider pattern). Settings → AI → Recipe
  units picker writes via `PUT /api/profile`.
- Tests: `tests/test_unit_system.py` (6 cases — defaults, normalize,
  directive content, week-planner injection, per-dish injection).
  302/302 backend pass.

**Build bump**: 49 → 50. Backend has no migrations — pure prompt
+ profile-setting change. Fly deploy + TestFlight build 50 follow.

### Earlier session (build 49 / Fly v75 — M26 Savanne dogfood, all 5 phases)

**Build 49** bundles M26 phases 1–5 in one TestFlight slice:

- **Phase 1 — Meal-card word wrap**: dropped `.lineLimit` on
  `CompactMealCard` + `TodayMealCard` recipe-name text; HStack
  switched to `alignment: .top` so slot label + checkmark stay
  pinned to the first line of a wrapped title.
- **Phase 2 — Sides on a meal**: new `week_meal_sides` table
  (migration `0032`); `WeekMealSide` model + cascade-delete
  relationship; `app/services/sides.py` (add/update/delete + auto
  grocery regen); REST endpoints under
  `/api/weeks/{w}/meals/{m}/sides`. Grocery aggregation in
  `build_grocery_rows_for_week` walks each meal's sides and folds
  recipe-linked sides into the grocery list scaled by the parent
  meal's `scale_multiplier`. iOS: `WeekMealSide` model, API client
  methods, `MealSidesSheet` reachable from the meal action sheet's
  "Manage Sides" item, side pills below the recipe name on both
  card variants. 5 new tests passing.
- **Phase 3 — Per-household shorthand dictionary**: new
  `household_term_aliases` table (migration `0033`);
  `app/services/aliases.py` (case-normalized term, household-scoped
  upsert); `app/api/aliases.py` GET/POST/DELETE; `gather_planning_context`
  + `_planning_context_text` inject the alias map as a "treat term
  X as expansion Y" preamble in both planner and assistant prompts.
  iOS: `HouseholdTermAlias` model, API client, AppState helpers,
  `HouseholdAliasesView` reachable from Settings → AI → Custom
  terms. 6 new tests passing.
- **Phase 4 — Event dish recipe linking + AI gen**:
  `event_ai.generate_recipe_for_meal` per-dish helper extracted
  from the existing menu pipeline; new `POST /api/events/{e}/meals/{m}/ai-recipe`
  returns a `RecipePayload` draft (no DB persist — human-in-loop).
  iOS: `generateEventMealRecipe` API method, "Generate recipe with
  AI" section in `EventMealEditorSheet` that calls the route, saves
  the draft as a Recipe, links it to the event meal. 3 new tests
  passing.
- **Phase 5 — AI dry-run confirm for swaps**: `_run_swap_meal` no
  longer mutates — returns a structured `proposed_change` payload
  in `AssistantToolResult.data`. Two new tools `confirm_swap_meal`
  (applies) and `cancel_swap_meal` (no-op ack). Tool descriptions
  teach the LLM the propose-then-confirm pattern. iOS: new
  `ProposedChangeCard` rendered inside `AssistantToolCallCard` when
  the tool result carries a `proposed_change` payload — Was/Becomes
  diff with Confirm/Cancel buttons that send follow-up assistant
  messages so the LLM dispatches the apply/cancel tool. 3 new
  tests passing.

**Test status**: backend `pytest -q` 296/296 (290 pre-M26 + 5 sides
+ 6 aliases + 3 event recipe + 3 dry-run minus 1 retired). iOS
build green on `Seedkeep iPhone` simulator.

**Build bump**: `CURRENT_PROJECT_VERSION` 48 → 49. Backend has new
migrations `0032` (week_meal_sides) + `0033` (household_term_aliases)
ready for `fly deploy`.

### Earlier sessions (build 35 → 48: M22.5 / M23 / M24 / M25)

**M22.5 + diagnostics hotfix** addresses build-35 dogfood:

- **M22.5 — sync feedback now actually surfaces**: the
  `reminderListIdentifier`, `lastReminderSyncAt`,
  `lastReminderSyncSummary` were UserDefaults-backed computed
  properties on `AppState`. `@Observable` only tracks stored
  properties, so SwiftUI never re-rendered when those changed —
  Settings → Grocery looked frozen after every Sync now tap. Moved
  to true stored properties on `AppState`, hydrated in
  `loadCachedData()` via new `loadReminderState()`, and persist
  to UserDefaults as a side effect.
- **API error context**: when the server returns 4xx/5xx, the iOS
  error now appends `[404 /api/path]` so a generic `"Not Found"`
  banner tells us which endpoint actually 404'd. (Build 35 surfaced
  a bare `"Not Found"` with no path; impossible to debug.)
- **Stale-error clear on Sync now**: tapping the manual sync button
  clears `lastErrorMessage` so a previous unrelated error doesn't
  masquerade as a sync failure.
- **Build 35 → 36**, TestFlight upload follows.

### Earlier same day (build 35)

**M22.3 + M22.4 + M23 hotfix** addresses dogfood feedback:

- **M22.3 — Reminders sync visibility**:
  - Each reminder now commits individually (`commit: true` per save).
    The previous batched `commit: false` + final `eventStore.commit()`
    pattern silently lost writes on iOS 26 in dogfood (sync said
    success, list stayed empty).
  - `upsertReminders` returns `(created, updated)` counts.
  - `syncGroceryToReminders` logs a human-readable summary via
    `lastReminderSyncSummary` ("Synced 12 items (12 created, 0
    updated).") and surfaces failures via `lastErrorMessage`.
  - Settings → Grocery now shows the summary plus a manual "Sync now"
    button so the user can retry without flipping the toggle.
- **M22.4 — auto-merge toggle hoisted**:
  - The toggle was inside `grocerySection` which only rendered when
    the event already had grocery items. Moved into a standalone
    `autoMergeRow` that's always visible on event detail (between
    attendees and Generate menu).
- **M23 hotfix — uv-native skill, no `.venv` ceremony**:
  - SKILL.md + README.md updated to use
    `uv run --project ~/.claude/skills/simmersmith-shopping ...`. uv
    reads `pyproject.toml` and manages the env transparently; no
    activation, no `.venv/bin/python`.
  - `cli.py` auto-installs Playwright Chromium on first browser-
    driving call so users don't need to remember `playwright install`.
  - `setup.sh` is now optional (just pre-warms cache + symlinks).
  - PyXA optional dep dropped — its PyPI release is stale; osascript
    fallback works on every Mac without extras.
- **Build 34 → 35**, deploy + TestFlight follows.

### Earlier same day (M22.1 + M22.2 + M23 ship — build 34)

**M22.1 + M22.2 limitation fixes + M23 skill scaffolding** shipped:

- **M22.1 — background Reminders sync**: new
  `SimmerSmith/Services/BackgroundSyncService.swift` registers a
  `BGAppRefreshTaskRequest` (identifier `app.simmersmith.ios.grocerySync`).
  iOS now wakes the app periodically to pull Reminders deltas back to
  the server even while it's backgrounded. `Info.plist` gains
  `BGTaskSchedulerPermittedIdentifiers` and `fetch` + `processing`
  background modes.
- **M22.2 — track event_quantity separately**: new
  `grocery_items.event_quantity` column +
  `alembic/versions/20260503_0029_grocery_event_quantity.py`.
  `merge_event_into_week` now writes the event delta into
  `event_quantity` instead of bumping `total_quantity`. Smart-merge
  regen can refresh `total_quantity` (week-meal portion) without
  disturbing the event contribution. iOS's `effectiveQuantity` sums
  the two for display. `_match_keys` now indexes by both base-id and
  normalized-name so a catalog-resolved week row still matches a
  name-only event row. New backend test
  `test_event_merge_uses_event_quantity_column`. 272 backend tests pass.
- **M23 — cart-automation skill scaffolding**:
  `skills/simmersmith-shopping/`. Full Python package:
  - `SKILL.md` + `README.md` for Claude Code discovery + setup.
  - `setup.sh` creates `.venv`, installs deps, runs `playwright
    install`, symlinks into `~/.claude/skills/`.
  - `parser.py` — permissive `<qty> <unit> <name>` parser handling
    fractions ("1 1/2 cups") and multi-word units ("fl oz").
  - `reminders.py` — PyXA + osascript fallback for reading the
    SimmerSmith Reminders list.
  - `splitter.py` — greedy + 2-store-combination heuristic
    minimizing cost subject to per-store delivery minimums and a
    configurable max-stops cap.
  - `stores/aldi.py` + `stores/walmart.py` — concrete Playwright
    drivers with real selectors. `stores/sams_club.py` +
    `stores/instacart.py` — login-only stubs the user fills in
    after the first interactive login captures cookies.
  - `cli.py` — orchestrator with `login --store X` (interactive
    cookie capture), `--dry-run` (synthesize prices for splitter
    verification), and the full Reminders → split → cart-fill
    pipeline.
  - 8 smoke tests pass (parser + splitter, no Playwright deps).
- **Build 33 → 34**, deploy + TestFlight to follow.

### Earlier same day (M22 ship)

**M22 Grocery list polish + Apple Reminders sync** shipped end-to-end:
- Phase 1 — schema + smart-merge regen + 5 mutation routes + 11 new
  backend tests (271 total pass).
  - `grocery_items` extended with 8 mutability fields
    (`is_user_added`, `is_user_removed`, `quantity_override`,
    `unit_override`, `notes_override`, `is_checked`, `checked_at`,
    `checked_by_user_id`) and `events.auto_merge_grocery`.
  - Smart-merge regeneration replaces the old wipe-rebuild — user
    edits, household-shared check state, and event-merge attribution
    survive meal changes.
  - 5 new routes under `/api/weeks/{id}/grocery/...`:
    POST `/items`, PATCH `/items/{id}`, POST/DELETE `/items/{id}/check`,
    GET `/grocery?since=ISO8601` (delta endpoint for Reminders sync).
  - Per-event `auto_merge_grocery` toggle wired through
    `apply_auto_merge_policy` so events fold into the week
    automatically when the toggle is on.
- Phase 2 — iOS surfaces.
  - SimmerSmithKit: `GroceryItem` extended with mutability fields +
    `effectiveQuantity/Unit/Notes` accessors. New `GroceryListDelta`
    response model. `Event` carries `autoMergeGrocery`.
  - 6 new API client methods + Sendable patch-body builders.
  - `AppState+Grocery.swift` (add/edit/remove/restore + local
    mirror helpers) and `AppState+Reminders.swift` (push and pull
    direction sync).
  - `RemindersService.swift` + `GroceryReminderMapping.swift`
    (per-device JSON store of grocery_item_id ↔ EKReminder
    calendarItemIdentifier).
  - 5th tab wired (`AppState.MainTab.grocery` was scaffolded but
    unwired before M22). `GroceryTabView` + editable `GroceryView`
    (swipe to remove, tap to edit, "+" toolbar to add).
  - `AddGroceryItemSheet`, `GroceryItemEditSheet`,
    `ReminderListPickerSheet`.
  - Settings → Grocery section with two-way sync toggle + list
    picker. EventDetailView has the auto-merge toggle.
  - `Info.plist` adds `NSRemindersUsageDescription` +
    `NSRemindersFullAccessUsageDescription`. No new entitlement.
  - Sign-out clears the per-device Reminders mappings via
    `clearReminderMappings()` from `resetConnection`.
- Phase 3 — durable design notes for the future M23 cart-automation
  skill (Aldi / Walmart / Sam's Club / Instacart) appended to
  `.docs/ai/decisions.md`. Roadmap updated.
- Phase 4 — `CURRENT_PROJECT_VERSION` 32 → 33. Commit + Fly deploy +
  TestFlight build 33 to follow.

**Test status**: backend `pytest -q` 271/271 (260 pre-M22 + 11 new
grocery edits). SimmerSmithKit `swift test` 26/26. iOS build green
on `generic/platform=iOS Simulator`.

### Previous session (2026-05-01)

**M21 Household sharing** shipped end-to-end across 5 phases:
- Phase 1 (commit `edf9a0f`) — schema: `households`, `household_members`,
  `household_invitations`, `household_settings` tables. `household_id`
  column on Week / Recipe / Staple / Event / Guest, backfilled.
- Phase 2 (commit `eff6e8f`) — service rewrite + auth: `CurrentUser`
  carries `household_id` (lazy-create for legacy users); every shared-
  table query flips from `user_id` to `household_id`; writers populate
  `household_id` on construct; per-user data (DietaryGoal,
  IngredientPreference, PushDevice, etc.) intentionally stays user-scoped.
- Phase 3 (commit `c50c6ce`) — invitation API + tests: 5 routes (GET
  household, PUT name, POST/DELETE invitations, POST join). Auto-merge
  on join: joiner's solo content (recipes, weeks, staples, events,
  guests) is re-pointed to the target household; the empty solo is
  deleted. 12 new tests covering owner-only checks, expiry, single-use
  consume, cross-member visibility, per-user push isolation.
- Phase 4 (commit `0dbe4a4`) — iOS surfaces: `HouseholdSnapshot` model +
  5 API client methods + `AppState+Household.swift` + new
  `InvitationSheet` (display + ShareLink) + `JoinHouseholdSheet` +
  `HouseholdSection` in Settings (between Sync and AI). Owner sees
  editable name + member list + invite button + active codes with
  Revoke. Solo households see "Join a household".
- Phase 5 — build bump 31→32, push, deploy, TestFlight 32. (in flight)

**Test status**: backend `pytest -q` 260/260 (248 pre-M21 + 12 new
household-API tests). SimmerSmithKit `swift test` 26/26. iOS build
green on `generic/platform=iOS Simulator`.

### Previous session (2026-04-30)

Three milestones shipped end-to-end:

- **M17.1 Image-gen cost telemetry** — per-call `image_gen_usage` rows,
  30-day Settings rollup, admin `GET /api/admin/image-usage` behind the
  legacy bearer. Backend deployed to Fly v58. Commit `13e2a97`.
- **M18 Push Notifications** — APNs device registration + in-process
  APScheduler + iOS Settings toggles (default ON). User set the four
  `SIMMERSMITH_APNS_*` Fly secrets using the existing
  `AuthKey_46NXHV5UB8.p8` Apple Developer key (covers both APNs and Sign
  In with Apple). Backend deployed to Fly v58. TestFlight build 28
  uploaded; on-device validation pending. Commit `86f738c`.
- **M19 / M7 Phase 5 Anthropic tool-use** — Refactored
  `_run_openai_tool_loop` into a provider-agnostic
  `_run_provider_tool_loop` driven by a `ProviderAdapter` ABC with
  `OpenAIAdapter` and `AnthropicAdapter` implementations. Anthropic
  planning threads now run the same 11 tools the OpenAI path runs;
  `assistant.tool_call`, `assistant.tool_result`, and `week.updated`
  SSE events fire identically. 7 new tests (1 schema parity + 6
  Anthropic-loop). Uncommitted at session end.

### What landed this session (M18, Phases 1-4)

**Backend**
- `pyproject.toml` — added `aioapns>=3.2`, `apscheduler>=3.10`
- `app/config.py` — added 6 APNs/scheduler settings
- `app/models/push.py` (new) — `PushDevice` SQLAlchemy model
- `app/models/__init__.py` — exported `PushDevice`
- `alembic/versions/20260430_0025_push_devices.py` (new) — `push_devices` table
- `app/services/push_apns.py` (new) — `APNsSender`, `send_push`, `is_apns_configured`
- `app/services/push_scheduler.py` (new) — `start_scheduler`, `_tick_tonights_meal`,
  `_tick_saturday_plan` with injected `now_local` callable for tests
- `app/services/bootstrap.py` — added 4 push default rows to `DEFAULT_PROFILE_SETTINGS`
- `app/services/ai.py` — added `apns_device_token` to `AI_SECRET_KEYS`
- `app/api/push.py` (new) — `POST /push/devices`, `DELETE /push/devices/{token}`,
  `POST /push/test`
- `app/main.py` — wired push router + scheduler lifespan

**Tests** (`tests/test_push.py`, +18)
- Device register/upsert/unregister round-trips
- `send_push` honours `disabled_at`, marks 410 Unregistered
- Scheduler fires at matching time, skips outside window, respects quiet hours
- Toggle-off (`value=='0'`) suppresses push
- Default-on semantics (no rows = enabled)
- Saturday tick skips approved week, fires for draft/no-week

**iOS**
- `SimmerSmith/SimmerSmith/Services/PushService.swift` (new) — APNs registration + notification dispatch
- `SimmerSmith/SimmerSmith/App/SimmerSmithAppDelegate.swift` (new) — UIApplicationDelegate adapter
- `SimmerSmith/SimmerSmith/App/SimmerSmithApp.swift` — `@UIApplicationDelegateAdaptor`
- `SimmerSmith/SimmerSmith/App/AppState+Push.swift` (new) — push drafts + `savePushPreference` + `ensurePushBootstrap`
- `SimmerSmith/SimmerSmith/App/AppState.swift` — wired `ensurePushBootstrap()` after `syncImageProviderDraft`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift` — `NotificationsSection` added
- `SimmerSmith/project.yml` — `CURRENT_PROJECT_VERSION` 27 → 28
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` — `registerPushDevice` + `unregisterPushDevice`

**Infra**
- `tests/conftest.py` — `SIMMERSMITH_PUSH_SCHEDULER_ENABLED=false` so APScheduler never spawns in pytest

### Production state (mid-session)

- **Fly secrets**: All four `SIMMERSMITH_APNS_*` vars set this session
  (`TEAM_ID=K7CBQW6MPG`, `KEY_ID=46NXHV5UB8`, `PRIVATE_KEY_PEM` from the
  existing `AuthKey_46NXHV5UB8.p8`, `TOPIC=app.simmersmith.ios`).
- **Backend image deployed**: Fly v58 carries M17 + M18 + M17.1. M19
  uncommitted, undeployed at session end.
- **TestFlight**: build 28 uploaded (M18 surface). On-device validation
  of M18 push toggles + auto-permission-prompt + `POST /api/push/test`
  is pending the user installing build 28.

### Build status

- Backend: pytest **242/242** pass (29 new this session: 18 push +
  20 telemetry + 1 schema parity + 6 Anthropic + minus 16 covered by
  existing tests' updates). Ruff clean on all touched files.
- Swift tests: 26/26 pass.
- iOS build: green on `generic/platform=iOS Simulator`.

### Previous session

M17 (Gemini-direct image-gen per-user toggle) shipped end-to-end in
commit `51d6120`. M16, M15 detail in earlier sessions.

## Blockers

Three loose ends, all user-driven:
1. **M19 uncommitted** — `app/services/assistant_ai.py`,
   `tests/test_assistant_anthropic_tools.py`,
   `tests/test_assistant_tools.py`, plus a few doc updates. Commit +
   `fly deploy` when ready (no migration, no iOS work).
2. **TestFlight 28 device validation** for M18 push notifications —
   install + sign in + accept the auto-fired permission prompt + run
   the `POST /api/push/test` curl smoke test.
3. **Anthropic dogfooding for M19** — Settings → AI provider toggle
   → switch to Anthropic → planning thread tool-use parity check.
