# Architecture review v2 — from-zero re-run, 2026-07-02 (Fable 5)

User-directed full redo of the 2026-07-01 review's judgment layer (prior orchestrator was Opus).
Process: fresh 114-agent Sonnet evidence sweep (8 markdown mappers incl. live backlog alignment;
8 lenses — the v1 six PLUS steady-state/scale and product-truth; one adversarial skeptic per finding;
completeness critic) under an **anti-anchoring rule**: agents were barred from reading v1's report,
ADRs, or the SP-D specs. Fable then re-adjudicated every lead-tier judgment, personally code-verifying
the two highest-stakes claims. Two session-limit interruptions; resume re-ran only dead agents.
Reconciliation ADR: `decisions.md` 2026-07-02. Beads: label `arch-v2`.

## Headline: what from-zero found that v1 missed

Four criticals, three from the lenses v1 never ran:

1. **Cold-launch store/token split** (`r8q` interim → `e0a` proper): fresh in-memory store + persisted
   change token = silently partial store after every relaunch. Fable-verified (HouseholdSession.swift:131,
   HouseholdSyncEngine.swift:67, saveState wired at .stateUpdate). Reframed from the finder's
   "vanishing-data showstopper": SwiftData cache masks browsing, rebase heals writes — but auto-backups
   snapshot a partial household and it retro-explains the Week-not-found / participant-empty-week class.
2. **Rebase = local-always-wins** for 16/19 types (`6ce`): field-level lost-update on ordinary
   two-device edits. v1 had praised this seam — wrong (method lesson recorded).
3. **Published privacy policy factually false** (`5w8`): describes the retired server architecture;
   allergy-adjacent data now flows direct-to-AI-providers; 5.1.1 risk.
4. **Assistant dead ends** (`7pr`): Smith tab = ComingSoon; every non-Week entry point drops its
   context into it.

Product-truth also caught live-but-dead-backend UI: per-meal Create-with-AI + Manage-sides (`962`),
grocery archive load (`ebu`), ingredient link picker (validates 990.5.1), recipe memories (validates
990.4). Plus findings against the fleet's own day-old code: RepairScheduler isolation race + swallowed
collapse errors (`9zf`).

## Full verdict set

40 confirmed / 1 refuted (ToolRegistry capability boundary — same refutation both reviews). Corroborated
v1-era beads: dab (failed-save policy + quota), qrt (sync-status UI), pr9 (CKRecord aliasing), c7r
(engine wiring races), 3i0 (stale UI tests), g4r (backup export), 1sz (a11y — v2 softened: assistant
composer IS labeled), b3/990.9 caveats (migration receipts ≠ completeness). New P2/P3: share-accept
warning `lwi`, onboarding dead-code delete `mm1`, MetricKit telemetry `0g5` (critic's "how would we
know?" test), KeyStore accessibility `kde`, debug-share neutering `eig`. Scope adds: yqm (account-change
drops pending edits), c86 (repair rescans full history every tick), l00 (confirm app build in CI).

## Sound areas (verified good — twice, independently)

Sticky field-merge design + wiring; cascade-delete compensation; collapseWeeks drain-before-delete;
migration-runner idempotence; AssistantEngine cancellation; package layering + headless test discipline;
Keychain hygiene + SecretSanitizer coverage; production CKShare scope; aps-environment split;
PublicCatalogReader paging/degradation; additive-safe codec evolution; ports (vision/seasonal/reminders)
functional on-device paths.

## Critic gaps accepted as deliberate scope

Localization (English-only v1 stands), supply-chain sweep of vendored GoogleSignIn family (dies with
990.10), CloudKit schema promotion remains a manual Dashboard step (pb8/9wr note it), app-target test
coverage (god-object/protocol-seam track, post-launch).
