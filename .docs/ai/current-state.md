# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] `simmersmith-9w4` spec + adversarial review (`kimi-k3`, `glm-5.2`).
- [x] Required normal WAL, recovery-only catalog selection, owner/participant startup wiring.
- [x] Package tests + static app parse; report: `phases/normal-mode-crash-durability-report.md`.
- [?] awaiting human verify: cache-first OFF owner + participant add/delete immediate-force-quit matrix.

## Blockers
- `simmersmith-9w4`: code complete; device crash-durability evidence still required before closure.
- App-host tests blocked before compile by missing repo-local `ballast/`; do not change dependency config.
- `.beads/` database absent; do not reinitialize. `e0a` remains blocked by `h1g` + cross-account matrix.
- Shipping default stays off: `CacheFirstLaunchPolicy.staticDefault == false`, and non-debug/non-sandbox resolves to `staticDefault && receipt == .appStore`.

## Open questions
- Does the new cache-first-OFF build pass owner + participant add/delete force-quit recovery on device?
- Does build 173 participant cache warm-up remove the wife-device launch gap after two warm relaunches?
