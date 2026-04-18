# Phase Spec: Nutrition-Aware AI + Dietary Goals (M4)

## Why this, why now

SimmerSmith just shipped its core loop: AI plans → approve → grocery list → real-store prices. The next competitive step is the reason users will *stay* — an AI planner that hits their **dietary goals**, not just their taste preferences.

- **Differentiation**: simpler meal planners (Pepper, Eat This Much) either pick recipes OR count macros — not both with a preference-aware AI. Doing both is a moat.
- **Leverage existing infrastructure**: the backend already has a 42 KB+ in-memory ingredient catalog with USDA FDC calorie data and a `NutritionItem` model (`app/services/nutrition.py`, 345 lines, and `app/models/catalog.py`). Today it tracks calories only and is recipe-scoped. Expanding to per-day / per-week macro aggregation is an extension, not a rewrite.
- **Monetization hook**: "AI plans that hit your macros" is a natural premium-tier feature when freemium lands in M5.
- **Post-launch stickiness**: first-week users see AI quality; fourth-week users need a *reason to come back every Sunday*. Progress tracking is that reason.

## Goal

Users set a dietary goal (lose weight / maintain / bulk, or custom macros), and the AI week planner produces meals that land within ±10% of their daily calorie target and hit the macro split. The app shows daily + weekly progress with a simple ring/bar UI. If the week drifts, the AI proposes a fix.

## Scope

Backend + iOS. No schema migration for recipe models — nutrition lives on ingredients already. New DB table for user dietary goals. Extension of `PlanningContext` + the planner prompt. New iOS surfaces for goal setup and per-day/week totals.

**Not in scope**: full food diary (logging what they *actually* ate), barcode scanning, integrations with HealthKit / MyFitnessPal, per-meal nutrition editing, branded fitness-brand aesthetic. Those belong in M5+.

---

## Approach

### 1. Data model — ingredient-level macros

`BaseIngredient` and `IngredientVariation` already store `calories` + `nutrition_reference_amount` + `nutrition_reference_unit`. Extend both rows with optional `protein_g`, `carbs_g`, `fat_g`, `fiber_g` (all floats, nullable). USDA FDC ingestion script needs a one-time enrichment pass.

**Files**:
- `app/models/catalog.py` — add four nullable float columns on `BaseIngredient` and `IngredientVariation`
- New Alembic migration
- `app/services/ingredient_catalog/` — update ingestion to write macros from FDC
- `app/services/nutrition.py` — extend `_calories_for_reference` / `_lookup_catalog_calories` with a sibling `_macros_for_reference` / `_lookup_catalog_macros` returning a `MacroBreakdown` dataclass

### 2. Data model — dietary goals

New `DietaryGoal` model, one per user, nullable.

```python
class DietaryGoal(Base):
    user_id: str  # unique
    goal_type: str  # "lose" | "maintain" | "gain" | "custom"
    daily_calories: int
    protein_g: int
    carbs_g: int
    fat_g: int
    fiber_g: int | None
    notes: str  # e.g. "diabetic, low sodium", free-form for AI
    updated_at: datetime
```

Presets for `goal_type` compute macros from calories using standard splits (40/30/30 for lose, 45/25/30 for maintain, 40/25/35 for gain). Custom = user enters raw numbers.

**Files**: `app/models/` (new file or extend profile), `app/schemas/` (DietaryGoal in/out), `app/api/profile.py` (PUT /api/profile/dietary-goal)

### 3. Per-meal / per-day / per-week aggregation

Add a presenter helper `meal_nutrition_breakdown(session, meal)` that:
- Iterates `meal.ingredients`
- Resolves each to a `BaseIngredient` or `IngredientVariation` (reuse `app/services/nutrition.py:_lookup_catalog_*`)
- Returns `MacroBreakdown(calories, protein_g, carbs_g, fat_g, fiber_g)` — scaled by meal servings × scale_multiplier

Aggregate up:
- **Per-day**: sum over meals where `meal_date == day`
- **Per-week**: sum over all meals in the week

Cache on `WeekOut` / `WeekSummaryOut` as `nutrition_totals: DailyTotals[]` + `weekly_totals: MacroBreakdown` so the iOS client gets it for free.

**Files**: `app/services/presenters.py`, `app/schemas/week.py` (extend `WeekOut`/`WeekSummaryOut`), `app/services/nutrition.py`

### 4. Planner integration

Extend `PlanningContext` (`app/services/week_planner.py`) with a `dietary_goal: DietaryGoal | None` field. Update `gather_planning_context()` to fetch it. Update `_build_system_prompt()` to append a **Dietary Goal** section when present:

```
DIETARY GOAL
- Daily target: 2100 calories, 150g protein, 210g carbs, 70g fat
- Type: maintain (45/25/30)
- Notes: diabetic — limit added sugar
- Rule: Design each day to land within ±10% of the daily calorie target.
- Rule: Prioritize recipes with protein_per_serving ≥ 30g for dinner.
```

Update the AI response schema (JSON schema) so the planner can optionally return `estimated_calories_per_serving` per recipe draft — we use this for cheap pre-scoring before actual ingredient lookup.

Extend `score_generated_plan()` to compute per-day totals on the *generated* plan and flag days that are >15% off target. Put flags in `week_notes` the same way guardrail warnings currently work.

**Files**: `app/services/week_planner.py`, `app/services/preferences.py` (score_meal_candidate can also factor macro fit)

### 5. iOS — goal setup

New screen `DietaryGoalView` in `SimmerSmith/SimmerSmith/Features/Settings/`. Reached from Settings → "Dietary Goal" row.

- Segmented control: Lose / Maintain / Gain / Custom
- Lose/Maintain/Gain: stepper for daily calories, preview of macro split
- Custom: four number fields for calories / protein / carbs / fat, optional fiber
- Notes text field
- Save → `PUT /api/profile/dietary-goal`

**Files**:
- `SimmerSmith/SimmerSmith/Features/Settings/DietaryGoalView.swift` (new)
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift` (new Section row)
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift` (`saveDietaryGoal`)
- `SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift` (`DietaryGoal` Codable + `MacroBreakdown` + `DailyTotals`)

### 6. iOS — nutrition display

Extend the Today hero and each day's card in `WeekView.swift`:
- Small macro ring under the day header: calories vs target, 4 thin bars for protein/carbs/fat/fiber
- Tap → bottom sheet with full per-day breakdown and each meal's contribution
- Weekly total chip at the top of the week grid

Reuse an existing SwiftUI library for rings — keep it native (`Gauge` with `.circular` style on iOS 16+, already available).

**Files**:
- `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift` (hero + day cards + weekly chip)
- New `SimmerSmith/SimmerSmith/DesignSystem/Components/MacroRing.swift`
- New `SimmerSmith/SimmerSmith/Features/Week/DayNutritionSheet.swift`

### 7. iOS — "Fix this day" CTA

When a day is flagged >15% off target, show an inline banner on that day's card: *"This day is 420 cal under your target. Ask AI to adjust?"* → tap → backend endpoint `POST /api/weeks/{id}/days/{day_name}/rebalance` which re-plans only that day's meals with the goal rule + existing preference context.

**Files**:
- `app/api/weeks.py` (new endpoint)
- `app/services/week_planner.py` (new `rebalance_day()` function that reuses the planner but constrains to one day)
- `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift` (banner + action)

---

## Acceptance criteria

- [ ] New Alembic migration adds `protein_g`, `carbs_g`, `fat_g`, `fiber_g` nullable columns to `BaseIngredient` and `IngredientVariation`; all 96 existing tests pass
- [ ] USDA FDC ingestion pass populates macros for ≥80% of cataloged ingredients
- [ ] `GET /api/profile` returns `dietary_goal` (null when unset); `PUT /api/profile/dietary-goal` persists
- [ ] `GET /api/weeks/{id}` response includes `nutrition_totals` (per-day) and `weekly_totals`
- [ ] Planner prompt includes dietary-goal section when goal is set; plans generated with a goal land within ±10% of daily calories on ≥5 of 7 days across 20 sample generations
- [ ] `score_generated_plan()` flags days that exceed ±15% drift; iOS surfaces the flag
- [ ] iOS Settings → Dietary Goal → set → return to Week → per-day macro rings render with correct colors (green in-range, amber close, red drift)
- [ ] Tap a day → bottom sheet shows per-meal nutrition breakdown with ingredients and their individual macro contributions
- [ ] "Rebalance this day" action regenerates just that day's meals and preserves others
- [ ] On-device test on TestFlight: set a goal → generate a week → verify daily rings populate and one off-target day surfaces a rebalance CTA

---

## Sequencing (recommended)

1. **Backend data + aggregation** (migration, catalog macros, aggregation, API surface) — ~2 sessions
2. **Goal model + Settings UI** — ~1 session
3. **Planner integration + guardrails** — ~1 session
4. **iOS nutrition display** (rings, day sheet, weekly chip) — ~1-2 sessions
5. **Rebalance CTA** (backend + iOS wiring) — ~1 session

Each step is independently shippable. After step 1–2, users can set a goal and see totals; after step 3, the AI respects it; after step 5, they can course-correct.

---

## Risks

- **FDC enrichment coverage**: USDA macros for unusual ingredients (e.g. "za'atar") may be missing. Fallback: ask the AI to estimate during recipe draft and store that estimate, flagged as `"nutrition_source": "ai_estimate"` so users see low-confidence numbers with a caveat.
- **Per-serving arithmetic**: meals have `servings` and `scale_multiplier`. Per-person totals require dividing. Consolidate the scaling logic into one utility to avoid drift between week_planner, presenters, and iOS.
- **Model output quality**: even with macros in the prompt, the AI will sometimes ignore them. Mitigation: the post-generation check catches egregious drift (>15%) and the rebalance CTA gives the user a one-tap fix.
- **UI complexity**: four-macro ring on a small card risks clutter. Prototype early; if it's crowded, fall back to calories ring only with macros in the sheet.

---

## Out of scope (parked)

- Logging what was actually eaten vs planned ("food diary")
- HealthKit / MyFitnessPal / Apple Health integration
- Weight-tracking charts
- Macros on manually-typed freeform meals (text like "leftover pizza" won't resolve to nutrition — show "—")
- Branded recipe macros override (we'll trust USDA for now; branded variations can ship later)
- Per-meal edit to override nutrition (defer until users ask)
- Push notifications for goal milestones (belongs in the APNs milestone)
