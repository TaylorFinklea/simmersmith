# Current State
Branch: main
Status: explicit per-provider AI data-sharing consent implemented; ready for next RC.
Reports: `phases/ai-data-sharing-consent-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Gate every shipping direct-AI seam on versioned, per-provider local consent.
- [x] Add Settings disclosure, Allow/Not Now/revoke controls, and privacy-policy disclosure.
- [x] Verify consent/failover tests, packages, legal site, and iOS test build.
- [?] Build 177 device retest remains on main: Roshar repeated photo replacement + participant gate.

## Blockers
- Human legal review and live ASC privacy questionnaire remain required.
- Next RC needs physical-device consent UI smoke plus the independent Roshar build-177 gate.
- `.beads/` absent; do not reinitialize.

## Verification
- Consent 9/9; site 3/3; Kit green; CloudKit 704/704; iOS test build succeeded.
