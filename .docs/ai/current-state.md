# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

## Current (2026-06-22) — SP-C CloudKit cutover MERGED to main + cleaned up

Branch `sp-c/cloudkit-cutover-identity` MERGED to `main` (`a9e8d8a`, --no-ff). NOT pushed (local only).

**Status:** Cutover validated on-device (build 120: recipes restored via Start Fresh; Weeks/Grocery/
Events/Pantry/Profile + AI-1 week-gen all live) → merged → dead-code cleanup landed (GoogleSignIn gone,
self-hosted UI gone, current-state trimmed, stray review docs dropped).

**Done:** Identity → AI-1 (6 slices) built/reviewed/on-device-validated; factory-reset "Start Fresh from
Fly"; household-discovery orphan-recipes fix; dead-code cleanup; merged to main.

**Open items (human):** push `main` when ready (not pushed); CloudKit Production schema deploy for full
re-import of weeks/events/pantry (recipes already deployed).

**Deferred follow-ons:** AI-2 (recipe import/variations) · AI-3 (nutrition/event AI) · AI-4 (AI images) ·
AI-5 (assistant) · CKShare-participant · SP-D (retire Fly + dead Fly fallback branches). Backlog:
PrivatePlaneStore SwiftData tests crash under macOS `swift test` (pre-existing, masked — see roadmap).
