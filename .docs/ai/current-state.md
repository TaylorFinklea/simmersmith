# Current State
Branch: main
Status: privacy/terms re-host published from `main`; legal/ASC review remains.
Reports: `phases/privacy-terms-rehost-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Replace server-era privacy/home/support claims; add Terms page and complete site navigation.
- [x] Centralize Pages legal URLs; use them in paywall and Settings → About.
- [x] Refresh claims-vs-code audit and preserve human ASC/legal decisions.
- [x] Verify app/packages/site; merge/push; confirm Pages built `a96095f` and both legal URLs.
- [?] Build 177 device retest remains on main: Roshar repeated photo replacement + participant gate.

## Blockers
- Human legal review and live ASC privacy questionnaire remain required.
- Roshar is not currently attached; device gate remains independent.
- `.beads/` absent; do not reinitialize.

## Verification
- Site 3/3; Kit 190/190; CloudKit 704/704; backend 597 passed/1 skipped; iOS build succeeded.
