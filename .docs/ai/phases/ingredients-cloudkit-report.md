# Ingredients CloudKit Milestone Report

Status: TESTFLIGHT BUILD 151 VALID — READY FOR DEVICE TEST
Date: 2026-07-12
Human gate: `simmersmith-cel` (`user-verify`)

## Delivered

- PUBLIC approved/active catalog browse, prefix search, ID lookup, variation references; read-only.
- Household base/product CRUD, detail, search, archive, deterministic merge + cross-record repair.
- PUBLIC + household + private-preference composition in AppState; zero live ingredient Fly calls.
- Grocery canonical linking; household-only edit/archive/merge/product controls.
- Complete owned Fly migration export (>200-safe) + owner-only receipt-gated import.
- On-device resolution: locked → existing → PUBLIC → household → provisional mint; preference overlay.
- Obsolete manual nutrition-match UI/client/API/MCP/ORM override removed; catalog macro calculator retained.

## Commits

- `4461658` plan/spec correction
- `e7d5d37` PUBLIC reader
- `8324a95` household repository
- `497481d` merge/repair
- `f25b554` lifecycle/AppState/UI/grocery link
- `1320617` complete receipt-gated migration
- `31fccc6` pure resolver
- `e9da1f1` resolver binding + named preferences
- `804698a` nutrition-match removal

## Automated evidence

- Backend: `594 passed, 1 skipped`; focused ingredient migration `11 passed`; nutrition `2 passed`.
- CloudKit packages: `492 passed`.
- SimmerSmithKit: `187 passed`.
- Signed app suites: repository + migration + resolver integration + recipe mapping + product flow PASS.
- Product flow pins create → prefer → resolve → grocery link → merge/repoint → resolve again.
- App unsigned simulator build PASS.
- Changed Python files: Ruff PASS. Repo-wide Ruff: 21 pre-existing unused-import findings outside this milestone.

## Signed iCloud simulator readiness

- Rebuilt current `main` (build 151), installed, and launched `app.simmersmith.ios` on the iPhone 17 Pro / iOS 26.5 simulator.
- iCloud authentication is live: no `Not Authenticated` event after launch; CKSyncEngine saved the private household zone and records with empty failure lists.
- Signed XCUITest launch/tab-bar smoke PASS on the same simulator.
- App reaches the Week surface without a crash or fatal log. The test account reports 13 harmless empty households left by earlier development builds.
- The checklist below remains the human interaction gate; the host accessibility bridge is not authorized to drive Simulator UI in this harness.

## TestFlight cut

- Release archive and manual App Store export PASS for version 1.0.0, build 151.
- Exported IPA passes strict code-sign verification; `aps-environment=production`; `get-task-allow=false`.
- Apple package validation: `VERIFY SUCCEEDED with no errors`.
- Upload and processing: `VALID`, `APP_STORE_ELIGIBLE`, `IN_BETA_TESTING`, present in App Store Connect; delivery `af098ff8-9970-4e6f-9d4f-eae6a535ed4d`.
- A new `SimmerSmith App Store Build 151` provisioning profile was created for the current distribution certificate; the older active profile was preserved.

## Device product-test checklist

Prerequisites: signed-in iCloud device; current build; normal app use with no saved Fly connection.

1. Open Ingredients; search a known PUBLIC ingredient. Expect row/detail, products, no Manage controls.
2. Create household base + product. Expect `Mine`; edit/product/archive controls visible only on household row.
3. Search by base name, product name, brand, and UPC. Expect the same household base each time.
4. From Grocery, link an item to the base. Expect canonical locked link; existing user-entered display text stays intact.
5. Save preferred product/brand. Reopen preference; expect readable base name and selected product.
6. In recipe editor, select an autocomplete result, edit its name, then resolve again. Expect no stale base/product link.
7. Create a duplicate household base, link recipe/grocery/preference data, then merge into target. Expect all links and preferred product repaired; source archived.
8. Inspect a PUBLIC ingredient again. Expect read-only behavior after all household mutations.
9. Open recipe nutrition with an unmatched ingredient. Expect passive `No catalog nutrition data yet`; no match chevron/sheet.
10. Relaunch. Expect household catalog/preference/link state to persist with no Fly connection.

Optional destructive migration proof: Settings → Start Fresh from Fly only if intentionally wiping local/CloudKit household data. Expect `Ingredients: Imported`; >200 owned rows and archived/merged rows are migration-safe by automated test.

## Residuals

- Full-macro PUBLIC coverage depends on curator republish bead `h2h`; calories-only rows remain supported.
- Historical Alembic table for manual matches remains inert; no destructive schema drop was added.
- Real iCloud UI proof is pending only on `simmersmith-cel`.
