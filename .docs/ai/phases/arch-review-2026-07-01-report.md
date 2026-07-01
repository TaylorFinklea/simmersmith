# Architecture review — 2026-07-01 (Fable 5 Lead, ultracode)

Process: two dynamic-workflow passes (80 Sonnet-5 agents, ~5.1M tokens): 8 subsystem
mappers + roadmap-alignment + 6 review lenses (sync-data-integrity, concurrency,
seams-coupling, error-silent-failure, launch-risk, security-privacy), one adversarial
skeptic per finding, completeness critic. Pass 2 re-ran most lenses live (resume after
one agent died) → acted as an independent second review; findings cross-corroborated.
User decisions taken via structured Q&A; ADRs 2026-07-01 in `decisions.md`. All work
filed as beads (`bd ready`), label `arch-review` / `sp-d`.

## Verdict

CloudKit-era core is well-built where designed deliberately: clean one-way package
layering (app → SimmerSmithKit → SimmerSmithCloudKit products; no inversions), strong
descriptor-driven AI seam + SSE machinery, sound zone-ownership + field-merge design,
475 fast headless tests. Problems cluster at seams/edges: (1) data-loss paths repeating
the build-141 full-REPLACE class, (2) a live paywall with dead fulfillment, (3)
architecturally invisible failures (print-only logging, unwired error plumbing), (4)
seven features still silently Fly-backed.

## Confirmed findings → beads

Data loss (P1): assistant `weeks_update_meals` full-REPLACE (ToolRegistry.swift:212 →
`enx`, the review's only CRITICAL); Backup RECOVER reverts newer edits on non-merger
types (AppState+Backup.swift:155 → `9i6`); WeekRepairAdapter + grocery dedupe never
wired into production sync (→ `gju`).

Launch (P1): real-money paywall, Fly-only fulfillment (SettingsView.swift:326-383,
PaywallSheet:185-209 → `7f2`); no PrivacyInfo.xcprivacy w/ required-reason APIs
(→ `he2`); unguarded Reset/Sign Out (SettingsView:546/564 → `ary`); Fly-migration
sections shown to every user (SettingsView:576-582 → `8o7`).

Hardening (P2): failed-save default log-only incl. quotaExceeded unhandled
(HouseholdSyncEngine:259-294 → `dab`), lastSyncError unobserved by any UI + participant
6x-retry silent give-up (→ `qrt`, blocked by dab); merger/zoneEnsured wire-after-boot
races (→ `c7r`); CKRecord cross-actor aliasing (→ `pr9`); withObservationTracking
re-registration gap ×8 repos (→ `7mb`); BGTask double-complete + APNs .noData-before-work
(→ `pwf`); no iCloud account-change handling post-launch (→ `yqm`); print-only logging,
no crash reporting, no log export (→ `79y`); SecretSanitizer shape-only redaction
(→ `cry`); backup health invisible + plaintext PII export (→ `g4r`, user chose optional
passphrase).

Fly seams (SP-D, epic `990`, ADR-1 port-then-retire): live-but-broken Fly features →
ports 990.1 vision · 990.2 seasonal · 990.3 substitutions · 990.4 recipe memories
(lead-gated schema) · 990.5 ingredients design spike · 990.6 push→local · 990.7
Reminders→CloudKit (user: KEEP feature; device gate `cnx`). Retirement: 990.8 strip
branches (blocked by ports+7f2) → 990.9 bridge (HUMAN gate: pg_dump archive; loaders'
receipts don't prove completeness — see pb8 note) → 990.10 delete APIClient;
990.11 runbook + terms/privacy re-host FIRST → 990.12 delete Python.

Infra (P3): CI `l00` · entitled-host tests `aeu` (8 PrivatePlane tests currently never
run anywhere) · stale Fly UITests `3i0` · a11y `1sz` (zero a11y API usage) · dead code
`l9s` (AssistantView 542L, CoexistenceSpike; dormant GLM/Kimi/MiniMax kept until
OpenRouter device gate passes) · .storekit config `2kv`. P4: `c86` LocalStore growth,
`bx1` credits-gateway spec.

## Arbitrations (conflicting skeptic verdicts across passes)

Kept privacy-manifest bead (cheap insurance vs disputed rejection likelihood); kept
failed-save policy (mechanics agreed, only "forever" disputed); sided with refutation
on ToolRegistry needing a capability boundary (hardcoded 12-tool switch is bounded).

## Sound areas (verified good — don't "fix")

FieldMergeResolver/sticky-merge wiring; zone ownership + orphan-mint protections;
GroceryGenerator additive regen; migration-runner idempotence (receipt-last);
deleteCascading + collapseWeeks drain-before-delete; default ifServerRecordUnchanged
save policy everywhere; AssistantEngine cancellation design; Keychain
AfterFirstUnlockThisDeviceOnly keys never in CloudKit; AuthKey_*.p8 gitignored + never
committed (661 commits checked); production CKShare publicPermission .none;
reasoning traces never persisted; DebugGate receipt check.

## Known gaps this review did NOT cover (critic)

Sync latency characterization (how fast partner edits propagate); CloudKit query
perf/pagination at scale; localization (deferred: English-only v1, user OK);
mixed-build/downgrade behavior (record-type handling is string-typed — reassuring,
unverified); Ask-To-Buy/billing-retry StoreKit edges (needs `2kv`).

User decisions 2026-07-01: approve all · Reminders → port to CloudKit · backup export
optional passphrase · iOS 26.0 floor intentional (FoundationModels).
