# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

## Current (2026-06-22) — SP-C CloudKit cutover: VALIDATED ON-DEVICE, READY TO MERGE

Branch: `sp-c/cloudkit-cutover-identity` (6 slices, 41 commits).

**Status:** Cutover validated on-device — recipes restored via Start Fresh (build 120); all CloudKit
pipes + Weeks/Grocery/Events/Pantry/Profile + AI-1 (week-gen + BYO keys + allergy gate) proven live.
Remaining tasks: (1) schema deploy to CloudKit Production (one-click), (2) dead-code cleanup (current),
(3) merge to main.

**Slices completed & verified:**
- [x] 1 Recipes — merged to main
- [x] 2 Identity → 6 AI-1 — all built + reviewed-clean + on-device-validated

**Blockers:** None. Ready to merge after schema deploy.

**Deferred follow-ons:** AI-2 (recipe import/variations) · AI-3 (nutrition/event AI) · AI-4 (AI images) ·
AI-5 (assistant) · CKShare-participant · SP-D (retire Fly). `// AI TRACK` + `// CATALOG TRACK` markers
guide the next slices. Ingredient prefs empty until re-run import.
