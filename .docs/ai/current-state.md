# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-25

Shipped **M11 Photo-First AI** Phases 2–5 on dev. Phase 1 (recipe
scan via VisionKit) was discovered to already be live. The build is
queued at `CURRENT_PROJECT_VERSION 15` but **NOT yet deployed to Fly
or uploaded to TestFlight** — those are the next user-driven actions.

Origin: a product audit comparing Taylor's wife's original product
notes against the live app surfaced photo / multimodal AI as the
biggest gap (mentioned 3× in her notes, entirely absent from the
app). The user confirmed all four photo flows + Quick AI Wins as
the next two milestones; cooking-mode + Memories slotted as later.

### What landed this session (M11)

**Phase 1 — Recipe scan (already shipped)**
Discovered `RecipeImportView` already wires `VNDocumentCameraViewController`
+ `VNRecognizeTextRequest` + `pendingTextReview` end-to-end. The
backend `import-from-text` route accepts the OCR'd output. No work
needed — the audit just missed it.

**Phase 2 — Vision provider foundation (commit `ce0b7f8`)**
- `app/services/vision_ai.py`: strict-JSON `identify_ingredient` +
  `check_cooking_progress` with image content blocks for OpenAI
  (`image_url` data URL) and Anthropic (`image` source). HEIC →
  JPEG fallback for OpenAI compatibility.
- `tests/test_vision_ai.py`: 7 tests covering happy path, oversize
  rejection, MIME validation, bad-JSON failure, HEIC fallback,
  Anthropic routing.

**Phase 3 — Scan ingredient → identify (commit `0ba9caa`)**
- `app/api/vision.py` + `app/schemas/vision.py`: `POST
  /api/vision/identify-ingredient` w/ `IngredientIdentificationOut`
  (name, confidence, common_names, cuisine_uses, recipe_match_terms).
- iOS: `IngredientScannerView` (PhotosPicker → result card with
  cuisine uses + Find Recipes action) wired into Recipes view's
  plus menu. New SimmerSmithKit models: `CuisineUse`,
  `IngredientIdentification`, `CookCheckResult`.
- 4 route integration tests.

**Phase 4 — Barcode scan → product (commit `9f7f858`)**
- `app/services/kroger.py::search_product_by_upc` (passes UPC as
  `filter.term` + filters returned products to exact-UPC matches).
- `app/api/products.py`: `POST /api/products/lookup-upc` w/
  `ProductLookupRequest/Response`.
- iOS: `BarcodeScannerView` wraps `DataScannerViewController(
  recognizedDataTypes: [.barcode()])`; `BarcodeLookupSheet` shows
  brand + price + in-stock. Toolbar entry in `GroceryView` (only
  when a Kroger store is configured).
- `Info.plist` gains `NSCameraUsageDescription`.
- 4 route tests.

**Phase 5 — Cook check (commit `eadca4d`)**
- `app/api/recipes.py::recipe_cook_check_route`: `POST
  /api/recipes/{id}/cook-check`. Looks up the recipe + step text
  server-side and calls `check_cooking_progress`.
- iOS: per-step "Check it" camera chip on each step in
  `RecipeDetailView` opens `CookCheckSheet` → photo → inline verdict
  (on_track / needs_more_time / concerning) + tip + suggested mins
  remaining.
- 2 route tests.

**TestFlight prep**
- `SimmerSmith/project.yml` `CURRENT_PROJECT_VERSION` 14 → 15.
- `xcodegen generate` re-run — project is ready to archive.
- Backend deploy + archive/upload are pending user confirmation.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy; current = M10.1.
  M11 backend NOT yet deployed.)
- **Model**: `gpt-5.4-mini` (vision-capable; should work for
  identify-ingredient + cook-check without changes)
- **TestFlight**: build 14 (pre-M11)

### Build status

- Backend: ruff clean (vision module + tests), pytest 165/165 pass
- Swift tests: 26/26 pass
- iOS build: green on `generic/platform=iOS Simulator`
- Fly production: healthy; STALE wrt M11 backend
- TestFlight: STALE wrt M11

## Files Changed (this session)

Backend (new):
- `app/services/vision_ai.py`
- `app/api/vision.py`
- `app/api/products.py`
- `app/schemas/vision.py`
- `tests/test_vision_ai.py`
- `tests/test_vision_api.py`
- `tests/test_products_api.py`

Backend (extended):
- `app/api/recipes.py` (cook-check route)
- `app/main.py` (router registration)
- `app/schemas/__init__.py` (vision exports)
- `app/services/kroger.py` (UPC lookup)

iOS (new):
- `SimmerSmith/SimmerSmith/App/AppState+Vision.swift`
- `SimmerSmith/SimmerSmith/Features/Vision/IngredientScannerView.swift`
- `SimmerSmith/SimmerSmith/Features/Vision/BarcodeScannerView.swift`
- `SimmerSmith/SimmerSmith/Features/Vision/CookCheckView.swift`

iOS (extended):
- `SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift`
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipesView.swift`
- `SimmerSmith/SimmerSmith/Features/Grocery/GroceryView.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift`
- `SimmerSmith/SimmerSmith/Info.plist`
- `SimmerSmith/project.yml` (build 15 bump)

Docs:
- `.docs/ai/roadmap.md` — M11 marked complete, M12 stub
- `.docs/ai/current-state.md` — this file
- `.docs/ai/next-steps.md` — refreshed with deploy + TestFlight cut
