# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

## Current (2026-06-22) — SP-C COMPLETE: CloudKit cutover + full AI track, all on main

Both branches MERGED to `main` (--no-ff), NOT pushed (local only): `sp-c/cloudkit-cutover-identity`
(`a9e8d8a`, the data cutover) + `sp-c/ai-track` (`15e3b05`, AI-1..AI-5). main builds; 276 CK tests pass.

**Status:** The rearchitecture is built — no central server needed; everything runs on CloudKit +
on-device with the user's BYO key.
- **Data cutover (on-device VALIDATED, build 120):** Identity (no sign-in), Weeks/Grocery, Events,
  Pantry/Profile (NSPCKC private plane), factory-reset "Start Fresh from Fly", orphan-recipes discovery fix.
- **AI track (built + 2-lens reviewed, builds 121-124, on-device PENDING):** AI-1 week-gen · AI-2 recipe AI
  (JSON-LD import + variation/suggestion/companion/refine + web search) · AI-3 nutrition (catalog) + event
  AI + rebalance · AI-4 images (OpenAI/Gemini) · AI-5 the tool-calling Assistant (12 tools, private-plane
  threads). All via AIService/BYOKeyProvider, keys in Keychain.

**Open items (human):** push `main` when ready (124 commits, not pushed) · on-device verify the AI track
(add a BYO key in Settings → try generate-week, import-a-URL, an image, the assistant) · CloudKit Prod
schema deploy for weeks/events/pantry full re-import (recipes deployed; AI track added NO new types).

**Deferred follow-ons:** CKShare-participant (Savanne joins) · SP-D (retire Fly + the dead Fly fallback
branches). AI v2 refinements: token-streaming the assistant, full 49-tool set, web-search/exports tools,
full-macro nutrition (needs the catalog to publish macros). Backlog: PrivatePlaneStore SwiftData tests
crash under macOS `swift test` (pre-existing, masked — see roadmap).
