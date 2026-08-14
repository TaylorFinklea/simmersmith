# Current State
Branch: main
Status: build 175 `VALID`; physical-device QA found an owner-write release blocker.
Spec/report: `phases/recipe-photo-rendering-spec.md` / `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Merge recipe-photo rendering and prepare build 175; Verify: fast-forward merge + release-note preflight.
- [x] Archive, upload, and process build 175; Verify: `scripts/release-ios.sh` reported terminal `VALID`.
- [x] Manual Settings onboarding; Verify: all four screens traversed on Roshar/iOS 26.6.
- [?] Owner durability; cache-first OFF + synced, but writes reject before add/delete persistence can be tested.
- [?] Clean-account onboarding + participant durability; no eligible account/device available.
- [?] Photo UI; physical list/compact/detail, fallback, upload persistence, and rapid scroll pass; hero/offline/healthy-writer mutations remain.

## Blockers
- Roshar owner session rejects meal and image mutations with `Couldn't save this change safely`; `simmersmith-9w4` stays open.
- Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Neutral test photo remains on Honey Garlic Butter Salmon; remove failed safely on both devices.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
