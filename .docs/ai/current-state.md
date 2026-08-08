# Current State
Branch: main
Note: build 174 metadata `781bc3f`; Ballast retired from source/build/CI; upload not started.

## Plan
- [x] `jfn` product choices + mint-aware private-state design approved.
- [x] Durable spec + ADR: `phases/jfn-onboarding-spec.md`.
- [?] awaiting owner review of the written spec before implementation planning.

## Blockers
- `jfn`: implementation planning is gated only by owner review of the written spec.
- `simmersmith-9w4`: code complete; device crash-durability evidence still required before closure.
- Build 174 release: Apple Distribution identity present; blocked only by ASC Keychain entries + local `.p8`.
- `.beads/` database absent; do not reinitialize. `e0a` remains blocked by `h1g` + cross-account matrix.
- Shipping default stays off: `CacheFirstLaunchPolicy.staticDefault == false`, and non-debug/non-sandbox resolves to `staticDefault && receipt == .appStore`.

## Open questions
- Does `phases/jfn-onboarding-spec.md` accurately lock the intended implementation scope?
- Does the cache-first-OFF build pass owner + participant add/delete force-quit recovery on device?
