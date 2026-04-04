# Current State

## Active Branch

- `main`

## Recent Progress

- Burned through three small-model-safe backlog items in parallel:
  - expanded `docs/ai/mcp-tools.md` with concrete recipe, week, export, and assistant-thread flows for external MCP clients
  - added API coverage for ingredient browse/search filter behavior and week export listing behavior
  - expanded `SimmerSmithKit` payload decoding coverage for product-like ingredients, export runs, assistant threads, and recipe-ingredient fallback identity
- Retuned the shared roadmap so it now separates formal premium-model phases from a parallel small-model-safe backlog.
- Added explicit backlog governance to the roadmap:
  - smaller assistants may take narrow, localized, low-risk work in parallel
  - core product decisions, architecture, and contract changes stay out of that backlog lane
  - deeper findings should be promoted into formal roadmap or ADR work instead of being solved opportunistically
- Repaired the local Codex MCP OAuth sessions for `vercel` and `supabase` after stale refresh tokens caused `MCP startup incomplete` warnings during Codex startup.
- Cleared the cached OAuth state with `codex mcp logout`, re-ran `codex mcp login` for both servers, and verified a fresh `codex exec` turn completed without the prior `supabase` / `vercel` startup failures.
- Fixed the native `Clear Local Cache` behavior so it now immediately refetches from the saved server connection instead of leaving the app in an empty local-only state.
- This directly addresses the live QA regression where clearing cache made `Recipes` appear empty and `Manage Ingredient Catalog` show `Not found` even though the backend still had data.
- Re-verified the backend still contains live recipes after the cache-clear report:
  - `GET /api/recipes` currently returns 12 recipes
  - examples include `Simple Biscuits and Sausage Gravy` and `Poor Man's Burnt Ends`
- Validated the iOS/client slice with:
  - `swift test --package-path SimmerSmithKit`
  - `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO`
- Tightened the live ingredient-catalog search and browse behavior so the default app experience is now generic-first instead of product-heavy.
- Added a `product_like` classification to base ingredients and exposed it through the API/native models.
- Ingredient search and browse now hide product-like rows by default unless the caller explicitly opts in, while still allowing product-heavy rows to remain available in ingredient detail and review flows.
- Improved the cleanup heuristics so packaging-heavy names such as `French Chestnut Mustard Jar` are treated as product-like even when they do not carry strong source-brand metadata.
- Rebuilt the Docker backend, reran the live catalog cleanup, and re-verified the live API:
  - `GET /api/ingredients?q=biscuit&limit=20` now returns only `Refrigerated biscuits` by default
  - `GET /api/ingredients?q=mustard&limit=20` now returns only `Yellow Mustard` by default
  - `GET /api/ingredients?q=mustard&limit=20&include_product_like=true` still exposes the fuller product-heavy set when explicitly requested
- Prepared the latest iOS build for TestFlight distribution:
  - bumped `CURRENT_PROJECT_VERSION` from `1` to `2`
  - regenerated `SimmerSmith.xcodeproj`
  - produced a signed archive at `/tmp/SimmerSmith-TestFlight.xcarchive`
  - exported a valid App Store Connect IPA at `/tmp/SimmerSmith-TestFlight-export/SimmerSmith.ipa`
- Verified the exported IPA is correctly signed for `app.simmersmith.ios` with version `1.0`, build `2`, Apple Distribution signing, and an App Store provisioning profile suitable for TestFlight.
- Attempted direct App Store Connect upload from local Xcode tooling, but the upload is blocked on this machine by unusable local App Store Connect/Xcode account credentials.
- Added a first-class native `Ingredients` management area instead of leaving ingredient operations buried in Settings-only search flows.
- The app can now browse and search all known base ingredients with filters for:
  - needs review
  - ingredients with preferences
  - ingredients with product variations
- Added ingredient detail management on iOS:
  - edit canonical base ingredient fields
  - add and edit product variations
  - archive ingredients and variations
  - merge duplicate base ingredients
  - inspect source provenance, usage, and linked household preference state
- Moved ingredient-management entry points into the real product surface:
  - `Settings` now links into the dedicated `Ingredients` area
  - `Recipes` now has a `Manage ingredients` action that opens the same screen
- Added the first source-aware ingredient ingest pipeline:
  - `app/services/ingredient_ingest.py`
  - `scripts/seed_ingredient_catalog.py`
  - USDA FoodData Central for generic ingredients and calories
  - Open Food Facts for branded/package products and variation seeding
- Added a dedicated `SIMMERSMITH_USDA_API_KEY` server setting and Docker passthrough so the ingredient seed script can use a real USDA key without requiring the operator to pass it on the command line every run.
- Added local ignored `.env` support for the USDA key on this machine and rebuilt the Docker service so the container picks up the new configuration.
- Ran the first real USDA-backed catalog seed against the live Docker-backed database instead of only temp seed databases.
- Confirmed the live ingredient API now returns source-backed USDA rows with provenance, including examples like `Jam`, `Honey`, and `Mustard`.
- Confirmed biscuit search now returns live catalog results, including `Refrigerated biscuits`, against the main app database.
- Tightened the ingredient-catalog cleanup path after the first live seed exposed too much USDA noise:
  - USDA ingest now selects one best ingredient candidate per curated seed term instead of creating a row for every USDA search hit
  - USDA seed terms now use only `Foundation` and `SR Legacy` result sets instead of also ingesting `Survey (FNDDS)` rows
  - ingredient search now uses phrase-aware matching and singular/plural query variants instead of raw substring matching
  - literal imported names like `1 can refrigerated biscuits` are now ranked below cleaner generic catalog matches like `Refrigerated biscuits`
- Rebuilt and restarted the Docker backend after the catalog-search cleanup so the live app/API now use the refined ranking and matching rules.
- Verified the ingest pipeline against isolated temp databases:
  - USDA requests now fail cleanly under public `DEMO_KEY` throttling instead of crashing the run
  - Open Food Facts ingest created base ingredients and product variations while skipping intermittent `503` responses safely
- Fixed the in-progress backend/API slice so source-aware ingredient detail/edit/archive/merge behavior lines up with the current SQLAlchemy and native client contracts.
- Regenerated the Xcode project after adding the new native ingredient-management feature file and fixed the SwiftUI compile issues in the new screen structure.
- Added a native ingredient catalog browser in Settings so the operator can browse real base ingredients and launch preference editing from the catalog.
- Improved the ingredient preference editor:
  - it loads a first page of ingredients even with an empty query
  - search can be triggered from keyboard submit
  - empty states now explain whether the user is browsing or saw no matches
- Adjusted ingredient search ordering so cleaner generic matches rank ahead of more literal auto-created names.
- Tightened assistant direct-provider handling:
  - prompts now explicitly require non-empty `assistant_markdown`
  - failed assistant turns persist a visible error message instead of an empty-looking bubble
  - iOS assistant bubbles now render stored error text instead of appearing blank
- Fixed the first QA bug bundle from live iOS testing:
  - unresolved ingredient actions no longer route taps into the unit picker
  - quantity and unit are now on separate lines in the native recipe editor
  - assistant bubbles now show fallback text when a provider returns a recipe draft without markdown
  - provider-specific API keys are now stored and resolved separately for OpenAI and Anthropic instead of sharing one direct-provider secret
  - OpenAI model discovery is filtered to a smaller supported set instead of a broad provider dump
  - ingredient resolution now creates a base ingredient immediately when no safe existing match exists, so new imports become searchable without a server reseed
  - text import parsing now splits collapsed numbered-step lines such as `1. Mix. 2. Bake. 3. Serve.`
- Restarted the local backend on `http://localhost:8080` against the current code after discovering the previous process was stale.
- Re-verified the previously broken live endpoints:
  - `GET /api/ingredients?q=biscuit&limit=20` now returns catalog results
  - `GET /api/ingredient-preferences` now returns `200`
- Confirmed the current user direction is to decommission the web frontend and focus product work on the backend API, iOS app, and MCP surface.
- Added the first matching web-facing ingredient review UX so catalog resolution is no longer native-only.
- The web Recipes page now surfaces recipe-level review status:
  - recipes with unresolved or suggested ingredients show review-needed badges
  - the page can filter down to only recipes that still need ingredient review
- The web recipe editor now supports ingredient resolution per row:
  - visible canonical status badges
  - canonical base ingredient search/selection
  - product variation selection
  - product locking
  - in-place creation of new base ingredients and product variations
- Extended the web client types and API layer so recipe and grocery payloads carry canonical ingredient identity in the admin UI.
- Native ingredient review can now create missing catalog entities in place instead of forcing users to leave the current recipe flow.
- The recipe editor ingredient review sheet now supports:
  - creating a new base ingredient from the current ingredient row or search text
  - creating a new product variation under the selected base ingredient
  - immediately selecting the newly created catalog entity back into the current ingredient resolution flow
- Added native client API wiring for:
  - `POST /api/ingredients`
  - `POST /api/ingredients/{base_ingredient_id}/variations`
- Added a durable recipe import fixture corpus under `tests/fixtures/recipe_import` for:
  - URL import HTML / JSON-LD samples
  - direct text import samples
  - OCR / scan / PDF-style noisy text samples
- Moved the import tests away from large inline strings and onto the fixture corpus so new real-world failures can be added as files instead of buried in test code.
- Added a real-world-shaped Burnt Ends URL regression fixture that locks in structured parsing for:
  - `3 pounds beef chuck roast`
  - `2 Tablespoons yellow mustard`
  - alternative-note handling on rub / BBQ sauce lines
- Expanded regression coverage around:
  - import structure quality
  - ingredient parsing quality
  - grocery resolution quality via the canonical ingredient path
- Added a shared native ingredient review queue that centralizes:
  - unresolved or suggested recipe ingredients across the recipe library
  - grocery items with review flags or unresolved canonical matches
- The review queue is now reachable from both the `Recipes` and `Grocery` tabs.
- Review queue actions now route into the existing workflows instead of duplicating edit logic:
  - `Open Recipe` launches the existing recipe editor on the selected recipe
  - grocery review rows can open the structured household ingredient preference editor directly
- Structured ingredient preferences are no longer Settings-only:
  - recipe ingredient review can launch the same preference editor for the selected canonical base ingredient
  - grocery review can launch the same preference editor from queue rows when the grocery item is canonically resolved enough
- Added the first in-app structured ingredient preference editor in native Settings.
- Households can now list, add, and edit canonical ingredient preferences server-side using:
  - base ingredient search
  - stored variation selection
  - choice mode selection
  - optional preferred brand text
  - active/inactive state
- The native client now supports ingredient preference APIs for:
  - listing preferences
  - upserting preferences
- Added the first native ingredient-resolution review UX on top of the canonical ingredient catalog foundation.
- The iOS recipe editor now shows canonical ingredient status per row and opens a dedicated review sheet for:
  - suggested/resolved/locked state
  - base ingredient search/selection
  - variation selection
  - optional product lock
- The native client now has ingredient catalog API coverage for:
  - base ingredient search
  - variation listing
  - ingredient resolution
- The Recipes create menu now treats import methods as first-class actions:
  - Import from URL
  - Scan from Camera
  - Import from Photo
  - Import from PDF
- `RecipeImportView` now accepts a preferred launch mode so camera/PDF launches can jump directly into the relevant capture flow instead of forcing everything through a misleading URL-labeled entry point.
- Added the canonical ingredient catalog foundation under the active `Recipe import UX and hardening` roadmap milestone.
- New backend domain model:
  - `base_ingredients`
  - `ingredient_variations`
  - `ingredient_preferences`
- Extended recipe ingredients, inline week-meal ingredients, and grocery items with:
  - `base_ingredient_id`
  - `ingredient_variation_id`
  - `resolution_status`
- Recipe save/import and inline meal creation now resolve ingredient rows against the catalog while preserving the original recipe-facing text fields.
- Grocery generation now resolves through canonical ingredient identity and structured ingredient preferences before falling back to raw-string behavior.
- Nutrition now prefers variation nutrition overrides, then base ingredient nutrition, then the legacy string-matching fallback.
- Added ingredient catalog HTTP APIs and matching MCP tools so external AI clients can operate the same ingredient system as the app.
- Confirmed the current iOS import information architecture is misleading:
  - `Recipes` -> `Create` -> `Import from URL` opens the shared import sheet
  - that sheet also contains camera scan, photo import, and PDF import actions
- Re-prioritized the roadmap so recipe import UX and hardening is now the next active phase.
- Completed the AI/MCP validation pass and confirmed the live backend is healthy on the local token-protected server.
- Verified the Assistant works end to end with the direct-provider path using the saved OpenAI key:
  - `general` turns stream cleanly
  - `recipe_creation` turns return a draft recipe artifact and do not auto-save
- Verified provider-backed model discovery against the live backend:
  - OpenAI model discovery returns a populated list
  - the currently selected saved model resolves as `gpt-5.4-mini`
- Verified the standard `simmersmith` MCP server from an external Codex session:
  - `health` works
  - recipe listing works
- Re-verified the Streamable HTTP mode for the standard `simmersmith` MCP server with bearer-token auth.
- The roadmap is now ready to move back to the next product phase: `Import quality lab`.
- Added provider-backed model discovery for OpenAI and Anthropic so the iOS app can present a model picker instead of a freeform text field.
- The native Settings screen now fetches available models for the selected direct provider from the backend and saves the chosen model server-side.
- Direct-provider model selection is now resolved from server-side profile settings first, then environment defaults.
- Added iOS Settings support for server-side-only AI direct-provider key management.
- The app can now set or clear a stored direct-provider API key on the server without ever reading the key value back into the client.
- Exposed profile update wiring in `SimmerSmithKit` so the native app can update AI provider mode, direct provider selection, and the stored secret-presence state safely.
- Added a real standard SimmerSmith MCP server with repo-backed tools for recipes, profile, preferences, weeks, exports, and assistant threads.
- Added a stable wrapper script so Codex and other MCP clients can launch the SimmerSmith MCP server from anywhere.
- Registered the standard MCP server in Codex as `simmersmith` and removed the misleading `codex-local` entry.
- Added optional Streamable HTTP transport for the standard SimmerSmith MCP server, including simple static bearer-token auth for operator use.
- Added `docs/ai/mcp-tools.md` to document the SimmerSmith MCP surface, launch modes, auth, and recommended tool usage patterns.
- Replaced the Assistant's local `codex exec` fallback with two real execution paths:
  - direct OpenAI / Anthropic APIs when configured
  - remote MCP over Streamable HTTP when direct keys are absent
- Added a local development MCP bridge script that exposes `codex mcp-server` over Streamable HTTP without changing the app's runtime contract.
- Verified the backend against the local MCP bridge with no saved API keys:
  - health now reports MCP as available and selected as the default target
  - a general assistant turn (`Hi`) succeeds end to end
  - a recipe-creation turn returns a draft recipe artifact end to end
- Added MCP server configuration for the backend, including URL, auth token, and Codex tool names.
- Added a real MCP client adapter and runtime probe so health/capability reporting reflects whether the configured MCP server is actually reachable and exposes the expected Codex tools.
- Persisted the external MCP thread ID on assistant threads so subsequent turns continue with `codex-reply` instead of starting a fresh conversation every time.
- Updated the iOS Assistant and Settings surfaces so AI remains visible, but chat creation/send is disabled with setup guidance when neither direct providers nor MCP are executable.
- Kept the older heuristic recipe AI actions in place for now.

## Recent Commits

- `a8facb8` `test: expand SimmerSmithKit payload coverage`
- `0bb6625` `test: cover ingredient and export api edges`
- `0463dab` `docs: add mcp tool flow examples`
- `1485e62` `docs: retune roadmap and backlog lanes`
- `e57d9a1` `feat: clean up ingredient catalog search`
- `0dc16e7` `fix: address ios qa issues`
- `4c7ea74` `feat: add ingredient catalog creation in review flow`
- `798b900` `test: add recipe import fixture corpus`
- `5cb5374` `feat: add bulk ingredient review queue`
- `b3446b8` `feat: add ingredient preference settings`
- `76873ba` `feat: improve native recipe import review`
- `fc56fac` `feat: add canonical ingredient catalog foundation`
- `e40d4e1` `feat: add provider model discovery`
- `0b4a8fd` `feat: add server-side ai key settings`
- `e15eaa0` `feat: add http mode for simmersmith mcp`
- `7671198` `feat: add simmersmith mcp server`
- `011a591` `feat: add local codex mcp bridge`
- `42b9016` `fix: recover assistant chat after stream decode errors`
- `00249fa` `fix: repair assistant codex fallback stream`
- `75b8040` `feat: add central assistant chat workflow`
- `787ccf2` `feat: add recipe companion suggestion drafts`

## Changed Files In The Current Slice

- `docs/ai/mcp-tools.md`
- `tests/test_api.py`
- `SimmerSmithKit/Tests/SimmerSmithKitTests/SimmerSmithKitTests.swift`
- `docs/ai/roadmap.md`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Blockers

- TestFlight upload is still blocked on local App Store Connect credential state even though archive/export succeeded.
- Product modeling is still unsettled for imported/branded rows: some items likely belong as product variations under generic bases instead of remaining top-level base ingredients.

## Open Questions

- Should seeded branded/product rows eventually be converted into product variations under cleaner generic bases automatically, or only through explicit merge/review flows?
- Should the native `Ingredients` area keep product-like rows behind a toggle everywhere, or only in the main browse/search experience?

## Validation / Test Status

- roadmap and handoff docs reviewed for consistency across:
  - `docs/ai/roadmap.md`
  - `docs/ai/current-state.md`
  - `docs/ai/next-steps.md`
  - `docs/ai/decisions.md`
- `git diff --check` -> passed
- `.venv/bin/pytest tests/test_api.py -k "ingredient_search_hides_product_like_rows_by_default_but_can_include_them or ingredient_search_prefers_clean_generic_match_over_literal_import_name" -q` -> passed
- `.venv/bin/pytest tests/test_api.py -k "ingredient_catalog_routes_support_resolution_and_preferences or recipe_lifecycle_and_library_edits_do_not_change_planned_meals" -q` -> passed
- `swift test --package-path SimmerSmithKit` -> passed
- `codex mcp logout vercel` -> passed
- `codex mcp logout supabase` -> passed
- `codex mcp login vercel` -> passed
- `codex mcp login supabase` -> passed
- `codex exec --color never --json "Reply with OK and nothing else."` -> passed; completed a fresh Codex run without the earlier `MCP startup incomplete (failed: supabase, vercel)` warning

- `GET /api/recipes` confirms the backend still has 12 recipes after the cache-clear report
- `swift test --package-path SimmerSmithKit`
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO`
- `python3 -m compileall app tests scripts`
- `.venv/bin/pytest tests/test_ingredient_ingest.py tests/test_api.py -q`
- live Docker rebuild via `docker compose up --build -d`
- live API verification:
  - `curl -s 'http://localhost:8080/api/ingredients?q=biscuit&limit=20'`
  - `curl -s 'http://localhost:8080/api/ingredients?q=mustard&limit=20'`
  - `curl -s 'http://localhost:8080/api/ingredients?q=mustard&limit=20&include_product_like=true'`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipesView.swift`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`
- `SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift`
- `alembic/versions/20260401_0013_ingredient_sources_and_management.py`
- `app/api/ingredients.py`
- `app/models.py`
- `app/schemas.py`
- `app/services/ingredient_catalog.py`
- `app/services/ingredient_ingest.py`
- `scripts/seed_ingredient_catalog.py`
- `tests/test_api.py`
- `docs/ai/current-state.md`
- `docs/ai/next-steps.md`
- `docs/ai/decisions.md`

## Working Tree

- dirty during the TestFlight prep slice until the session-end commit is created

## Blockers

- TestFlight upload is currently blocked by `xcodebuild -exportArchive ... destination=upload` failing with `Failed to Use Accounts`.
- The machine has valid signing identities and can archive/export successfully, but the local Xcode/App Store Connect account is not currently usable for upload.
- the local MCP bridge still emits noisy `codex/event` validation logs from the upstream MCP SDK during tool execution, but calls still complete successfully

## Open Questions

- Should local TestFlight/App Store Connect uploads in this repo rely on repaired Xcode account credentials, an App Store Connect API key flow, or a future CI/release pipeline?
- Should the dedicated `Ingredients` area stay reachable from `Settings` and `Recipes`, or eventually become its own top-level tab?
- Should the first production catalog seed rely on:
  - a real USDA API key provided by the operator
  - a checked-in/generated local snapshot
  - or a mixed strategy with cached seed artifacts committed into the repo
- Do we want to keep Open Food Facts as best-effort enrichment only, given the intermittent `503` availability seen during smoke tests?
- Should exact branded-import matches auto-create/lock product variations, or only resolve to generic base ingredients unless the user confirms the product?
- Do we want to normalize obviously bad auto-created base ingredient names such as `1 can refrigerated biscuits` into cleaner generic catalog entries during import resolution, or leave that for the review workflow?
- Should Settings grow from a lightweight ingredient browser into a fuller catalog-management surface with edit/merge/archive actions for base ingredients and variations?
- When decommissioning the web frontend, do we want to remove it in one pass or freeze it first and only keep minimal maintenance while native/backend parity is confirmed?
- Should the current review queue remain a lightweight entry point into existing editors, or eventually gain inline resolution controls for bulk triage?
- Should the grocery web view also gain direct ingredient-resolution actions, or remain recipe-first for canonical review?
- Should import flows auto-accept exact base-ingredient matches silently and only surface variation/product review when household preferences exist?
- When a recipe explicitly names a branded ingredient, should that always become a locked variation or remain a resolved-but-editable suggestion?
- Should the existing heuristic suggestion / companion / variation routes migrate onto the same direct/MCP execution layer next, or stay lightweight until after import hardening?
- Do we want a user-facing server settings surface for MCP configuration later, or keep MCP transport config server-side only?
- Should the local bridge remain a dev-only helper script, or become a documented operator option for laptop-hosted MCP setups?
- Which external AI clients do we want to optimize first for the new standard SimmerSmith MCP surface beyond Codex?
- Do we want to keep static bearer-token auth as the only HTTP auth mode for now, or add a more formal auth story before recommending network exposure?
- Should server-side AI key management remain in the general Settings form, or move to a dedicated AI configuration screen once more provider controls exist?
- Should we filter the discovered OpenAI model list more aggressively to only reasoning/chat models we explicitly support, or keep the broader provider-visible list?

## Validation / Test Status

Latest completed validation for the TestFlight prep slice:

- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -configuration Release -destination generic/platform=iOS -archivePath /tmp/SimmerSmith-TestFlight.xcarchive -allowProvisioningUpdates archive` -> passed
- `xcodebuild -exportArchive -archivePath /tmp/SimmerSmith-TestFlight.xcarchive -exportPath /tmp/SimmerSmith-TestFlight-export -exportOptionsPlist /tmp/SimmerSmith-ExportOptions.plist -allowProvisioningUpdates` -> passed
- exported IPA present at `/tmp/SimmerSmith-TestFlight-export/SimmerSmith.ipa`
- `xcodebuild -exportArchive ... destination=upload ...` -> failed with `Failed to Use Accounts`; upload not completed

Latest completed validation for the ingredient catalog foundation slice:

- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_grocery.py tests/test_api.py -q` -> passed (`28 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the native import UX and ingredient review slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the structured ingredient preference settings slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the ingredient-management and ingest slice:

- `python3 -m compileall app tests alembic scripts` -> passed
- `.venv/bin/pytest tests/test_api.py tests/test_grocery.py tests/test_recipe_import.py -q` -> passed (`42 passed`)
- `swift test --package-path SimmerSmithKit` -> passed (`12 tests`)
- `xcodegen generate --spec SimmerSmith/project.yml` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed
- `SIMMERSMITH_DATA_DIR=/tmp/simmersmith-seed SIMMERSMITH_DB_PATH=/tmp/simmersmith-seed/ingredients.db .venv/bin/python scripts/seed_ingredient_catalog.py --page-size 5 --max-pages 1` -> passed end to end with graceful USDA `429` skips
- `SIMMERSMITH_DATA_DIR=/tmp/simmersmith-seed-off SIMMERSMITH_DB_PATH=/tmp/simmersmith-seed-off/ingredients.db .venv/bin/python scripts/seed_ingredient_catalog.py --no-usda --include-open-food-facts --page-size 3` -> passed end to end with partial Open Food Facts ingest and graceful `503` skips
- `docker compose up --build -d` -> passed
- `curl http://localhost:8080/api/health` -> passed
- `.venv/bin/python -c "from app.config import get_settings; print('set' if bool(get_settings().usda_api_key) else 'missing')"` -> passed (`set`)
- `docker compose exec simmersmith sh -lc 'cd /workspace && PYTHONPATH=/workspace python scripts/seed_ingredient_catalog.py --page-size 25 --max-pages 1'` -> passed against the live database; USDA-backed ingredient rows are now visible via `/api/ingredients`
- `curl 'http://localhost:8080/api/ingredients?q=biscuit&limit=20'` -> passed; live biscuit-related catalog rows are now visible
- `python3 -m compileall app tests scripts` -> passed after curated USDA ingest + search cleanup
- `.venv/bin/pytest tests/test_ingredient_ingest.py tests/test_api.py -q` -> passed (`34 passed`)
- `docker compose up --build -d` -> passed after the ingredient-search cleanup patch
- `curl 'http://localhost:8080/api/ingredients?q=jam&limit=20'` -> passed; no unrelated `jambon` false-positive row remains in the live result set
- `curl 'http://localhost:8080/api/ingredients?q=biscuit&limit=20'` -> passed; `Refrigerated biscuits` now ranks ahead of the literal `1 can refrigerated biscuits` row

Latest completed validation for the bulk ingredient review queue slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the import fixture corpus and regression coverage slice:

- `python3 -m compileall tests app` -> passed
- `.venv/bin/pytest tests/test_recipe_import.py tests/test_api.py tests/test_grocery.py -q` -> passed (`37 passed`)

Latest completed validation for the ingredient review catalog-creation slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the web ingredient review UX slice:

- `cd frontend && npm run build` -> passed
- `cd frontend && npm test` -> passed (`2 files, 5 tests`)

Latest completed validation for the direct/MCP execution refactor:

- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`23 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the local MCP bridge slice:

- `.venv/bin/python -m py_compile scripts/codex_mcp_http_bridge.py app/services/mcp_client.py` -> passed
- local MCP probe via `run_codex_mcp(...)` against `http://127.0.0.1:8765/mcp` -> passed
- `GET /api/health` with `SIMMERSMITH_AI_MCP_BASE_URL=http://127.0.0.1:8765/mcp` -> MCP available and default target is `mcp`
- end-to-end assistant thread create/respond (`Hi`) over the live API with no direct-provider keys -> passed
- end-to-end assistant recipe creation turn over the live API with no direct-provider keys -> passed with `assistant.recipe_draft`

Latest completed validation for the standard SimmerSmith MCP server slice:

- `.venv/bin/python -m py_compile app/mcp_server.py scripts/run_simmersmith_mcp.py` -> passed
- stdio MCP smoke test via the Python MCP client -> passed
- tool listing returned 47 SimmerSmith tools
- MCP `health` tool call -> passed
- Codex global MCP registration now shows `simmersmith` as an enabled stdio MCP server

Latest completed validation for the SimmerSmith MCP HTTP/auth slice:

- `.venv/bin/python -m py_compile app/mcp_server.py` -> passed
- `scripts/run_simmersmith_mcp.py --transport streamable-http --host 127.0.0.1 --port 8766 --path /mcp --bearer-token test-token` -> server started successfully
- authenticated `curl` to `http://127.0.0.1:8766/mcp` with `Authorization: Bearer test-token` -> reached MCP server and returned protocol-level response
- authenticated Python MCP client via `streamable_http_client(...)` -> initialized successfully
- HTTP MCP tool listing returned 47 SimmerSmith tools
- HTTP MCP `health` tool call -> passed

Latest completed validation for the iOS AI key settings slice:

- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the provider model discovery slice:

- `python3 -m compileall app tests` -> passed
- `.venv/bin/pytest tests/test_recipe_import.py tests/test_api.py -q` -> passed (`38 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed
- live API smoke checks after backend restart:
  - `GET /api/health` -> passed
  - `GET /api/ingredients?q=biscuit&limit=20` -> passed
  - `GET /api/ingredient-preferences` -> passed

Latest completed validation for the ingredient-management and Anthropic UX follow-up slice:

- `python3 -m compileall app tests` -> passed
- `.venv/bin/pytest tests/test_api.py tests/test_recipe_import.py -q` -> passed (`38 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed
- live API smoke checks after backend restart:
  - `GET /api/health` -> passed with both direct providers available
  - `GET /api/ingredients?q=biscuit&limit=20` -> passed, with `Refrigerated biscuits` ranked first
  - `GET /api/ingredient-preferences` -> passed

- `python3 -m compileall app tests` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`24 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

Latest completed validation for the AI/MCP closeout pass:

- `GET /api/health` -> passed
- `GET /api/ai/providers/openai/models` -> passed, selected model `gpt-5.4-mini`, discovered models returned
- live Assistant `general` turn over the API with the current OpenAI key -> passed
- live Assistant `recipe_creation` turn over the API with the current OpenAI key -> passed with `assistant.recipe_draft`
- `codex exec` using the stdio `simmersmith` MCP server -> passed (`health` + recipe listing)
- `scripts/run_simmersmith_mcp.py --transport streamable-http ... --bearer-token test-token` + HTTP initialize request -> passed
- `python3 -m compileall app tests alembic` -> passed
- `.venv/bin/pytest tests/test_api.py -q` -> passed (`24 passed`)
- `swift test --package-path SimmerSmithKit` -> passed
- `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO` -> passed

## Runtime Notes

- The local backend is typically run on `http://localhost:8080`.
- Bearer token used in local testing: `2cc40b9addb61756ac8ab7e4405cab696ff68f8e8fe084c8`
- MCP execution now expects a remote Streamable HTTP MCP server configured via server settings / env vars.
- For local laptop development, `scripts/codex_mcp_http_bridge.py` can provide a Streamable HTTP MCP endpoint at `http://127.0.0.1:8765/mcp` backed by `codex mcp-server`.
- For external AI control of the app itself, `scripts/run_simmersmith_mcp.py` launches the standard SimmerSmith MCP server.
- Codex is now configured with a global MCP entry named `simmersmith` that launches the repo MCP server over stdio.
- The SimmerSmith MCP server can also be run over Streamable HTTP with optional static bearer auth by passing `--transport streamable-http --bearer-token ...`.
- The backend should no longer rely on local `codex exec` for Assistant turns.
- The iOS app now lets the operator set or clear a direct-provider API key, but the key itself is only stored server-side and is never returned in profile payloads.
- The iOS app now fetches the available model list for the selected direct provider from the backend and stores the chosen model server-side as profile state.
