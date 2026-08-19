# Current State
Branch: main
Status: explicit per-provider AI consent shipped in VALID TestFlight build 178; device smoke pending.
Reports: `phases/ai-data-sharing-consent-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Gate every shipping direct-AI seam on versioned, per-provider local consent.
- [x] Add Settings disclosure, Allow/Not Now/revoke controls, and privacy-policy disclosure.
- [x] Verify consent/failover tests, packages, legal site, and iOS test build.
- [x] Archive/upload build 178; App Store Connect processing reached `VALID`.
- [?] Build 178 device smoke: consent flow + Roshar repeated photo replacement + participant gate.

## Blockers
- Human legal review and live ASC privacy questionnaire remain required.
- Build 178 needs physical-device consent UI smoke plus the independent Roshar gate.
- `.beads/` absent; do not reinitialize.

## Verification
- Release/consent 24/24; site 3/3; Kit 190/190; CloudKit 704/704; build 178 `VALID`.
