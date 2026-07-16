# P8 — App-Owned Production-Cloud Baseline Runner (spec)

**Status:** approved 2026-07-16 (user sign-off on timing, harness, scoring — see Decisions);
revised same day after Sol adversarial review (NOT-CLEAR → all 9 findings folded; see §Review).
**Track:** prerequisite for `simmersmith-zyp`'s live FM non-inferiority gate. Independent of the
active e0a loop in `current-state.md` — phase checkboxes live HERE, not there.
**Worktree:** implementation in a fresh worktree (precedent:
`/Users/tfinklea/git/.worktrees/simmersmith-ballast-voice-parse/`); spec lives on main. Pin the
worktree's base commit and the SHA-256 of `CloudParseService.swift` at creation; every phase's
verify re-checks that hash (see Plan).

## Problem

`SimmerSmithBallastEval --live --baseline <file>` consumes a typed `productionCloudBaseline`
`VoiceParseEvalMetrics` JSON but nothing can produce one. `CloudParseService` and its AIService
configuration (SwiftData private plane + device Keychain) are app-target-only, so the SwiftPM CLI
can never run the production path. Without an honest baseline, `simmersmith-zyp`'s gate can never
run.

**Verified dead ends (do not revisit):**
- *macOS CLI*: `CloudParseService`/`AIService`/`HouseholdSession` are iOS-app-target sources
  (`SUPPORTS_MACCATALYST NO`); CloudKit-capable `@Model` types SIGTRAP in non-entitled macOS
  binaries; the BYO key exists only in the iOS device Keychain.
- *LanguageProvider shim through `VoiceParseEvalRunner`*: `WeeklyPlanWireEntry.evidence` is
  non-optional (`WeeklyPlanWirePayload.swift:8,23`) and production JSON never contains an
  `evidence` key, so every run fails decode → `RepairingGenerator` exhausts repairs → `.failed`
  (`RepairingGenerator.swift:85-95`). Result: a decodable all-fallback baseline (F1≈0,
  fallbackRate=1.0) that any candidate trivially beats. It would also layer
  `ParsedWeeklyPlanSchema.validate` (groundedness/domain checks) and Ballast repair semantics
  onto a production path that applies neither.

## Decisions (2026-07-16, user-approved)

1. **Timing** — spec + implement in a fresh worktree now; nothing merges to shipping behavior;
   the live 180-call run is separately gated on explicit user spend consent. This is eval
   infrastructure, not a Wave-3 product pull-forward; roadmap.md:89's rule stays intact for
   product scope.
2. **Harness** — in-app debug screen behind `DebugGate` (mirror `CloudKitDebugView`'s gating and
   Settings embedding), so the run measures the user's real production config/Keychain on-device.
3. **Scoring** — typed-output + 4-field baseline semantics (below). Candidate-side scoring and
   `VoiceParseEvalPolicy` constants are untouched.

## Honesty invariants (binding)

- Never fabricate, hand-edit, or partially emit metrics. A sweep that does not complete a *valid*
  `caseCount × runsPerCase = 180` (per the Run-validity policy) emits **nothing**.
- Never persist transcripts or raw model responses. Corpus transcripts are synthetic and
  git-committed; runner output is aggregates + non-secret identity only. Failure records keep
  sanitized error-*category* counts, never response bodies.
- Each of the 3 runs per case is an independent live call — no response caching or reuse.
- Cancellation is never data: a cancelled run is discarded, not recorded as a failure sample.
- `useBallastParse` stays false. This work never touches it.
- `CloudParseService` stays byte-identical (hash-pinned; mechanically verified per phase).
- Identity in the artifact is proven per-call by the identity lease (D2) — never typed in by
  hand, never assumed from a start-of-sweep snapshot alone.

## Run-validity policy (predeclared — decided before any live run exists)

Failure taxonomy for each of the 180 calls. **Rationale:** baseline failures *depress* baseline
metrics, which *lowers* the candidate's bar — so environmental noise in the baseline is
anti-conservative for the gate and can never be scored.

- **Abort class — first occurrence invalidates the sweep; nothing is emitted:** any terminal
  non-success HTTP status (401/403, terminal 400 after BYOKeyProvider's internal one-shot retry,
  429, 5xx — all of them), configuration/auth/session errors (`noProviderConfigured`,
  missing/empty key), URL/network errors and timeouts, task cancellation, app leaving `.active`
  scene phase, household-session teardown/epoch change, `aiService` instance change,
  identity-lease violation (D2).
- **Scored class — production model-quality failures → `producedResult=false`, `fallback=true`:**
  strictly an HTTP-*success* response whose body failed `BYOKeyProvider.extractJSONObject` +
  `ParsedWeeklyPlan` decode (including empty or non-JSON bodies). These are the production
  system's real parse failures and belong in the baseline. Nothing else scores.
- **No discretionary re-runs:** a valid 180/180 sweep is THE baseline for its config identity.
  Re-running requires a documented abort or a config-identity change (which re-stales the old
  file anyway). Post-result "I didn't like the numbers" re-runs are forbidden.
- BYOKeyProvider's one-shot structured-output-400 retries (`Providers.swift:239-252,297-310,
  367-379`) are transport-internal production behavior: not repairs (`repairRate` stays 0), and
  their latency lands in `meanLatencyMilliseconds`.
- Aborted sweeps leave no artifact; successful sweeps record scored-failure category counts in
  the provenance sidecar.

## Design

### D1 — Adapter: public baseline scoring path (`SimmerSmithBallastAdapter`)

`VoiceParseScorer` is private (`VoiceParseGoldenEval.swift:302`). Add a **public** baseline
entry point reusing its internals. **Order is binding (Sol F3):**

1. **Characterization tests first** — pin the *current* candidate scorer behavior before any
   refactor, with fixtures covering: case/whitespace normalization plus evidence-only
   punctuation/span divergence; expected `[A,A,B]` vs predicted `[A,B,B]` (multiset
   intersection); successful empty/nonempty, failed empty/nonempty, successful empty/empty;
   safety-critical and non-safety extra entries; crossed partial rows and a tie (greedy field
   pairing + 4-vs-5 denominators).
2. Then refactor to share `MealSignature`/`normalize`/`counts`/`intersectionCount` — do not
   duplicate ~150 lines.
3. Then **differential tests**: reusing the step-1 characterization fixture set verbatim, assert
   all shared metrics are identical after 4-field projection, with only the declared
   exact-match/fieldAccuracy differences.

**Public sample shape (Sol F4):** carries canonical `caseID`, `runIndex`, latency, and an outcome
enum — `success(rows)` with 4-field rows (day, slot, rawDish, intent) or `failure(category)`
(scored class only). **No transcript-bearing golden case in the public sample.** The throwing
scorer loads the frozen corpus resource internally, verifies the digest, and rejects the input
unless every `(caseID, runIndex 1...3)` appears exactly once — missing, duplicate, or unknown
cases throw. `caseRuns == 180` alone proves nothing; coverage is validated structurally.

**Baseline-role scoring semantics (spec-derived — these ARE the predeclared gate semantics):**

| Metric | Baseline semantics |
|---|---|
| entryPrecision / entryRecall / entryF1 | identical 4-field `MealSignature` math as `VoiceParseScorer.score` (`VoiceParseGoldenEval.swift:346-355,382-384`) |
| unsupportedEntryRate / safetyUnsupportedEntries | identical 4-field math (lines 350-358) |
| exactPlanMatchRate | multiset equality of **4-field** signatures (evidence excluded), counted only on `success` (mirror lines 359-362) |
| fieldAccuracy | `equalFieldCount` over the **4** production fields; total = `expected.count × 4` |
| repairRate | 0.0 by construction — production has no repair loop; `attempts` is always 1 |
| fallbackRate | fraction of case-runs whose outcome was a scored model-quality failure |
| emptyResultFalseNegativeRate | same rule as lines 371-376: counts only `success` with empty rows against non-empty expected |
| meanLatencyMilliseconds | `ContinuousClock` wall time around the single `CloudParseService.parse` call per run |
| provenance fields | role `.productionCloudBaseline`; `corpusID`/`corpusDigest` from `VoiceParseEvalPolicy`; caseCount 60; runsPerCase 3; caseRuns 180 (structurally validated) |

**Comparability declaration (predeclared before any live numbers exist):**
- `entryF1` is apples-to-apples across roles.
- `exactPlanMatchRate` compares the candidate's strictly harder 5-field predicate against the
  baseline's 4-field predicate. Sol-verified: the asymmetry can never flip anti-conservative
  (candidate 5-field exact ≤ its own 4-field projection).
- **Evidence-canonicality acknowledgment (Sol F2):** the candidate's exact-match leg is partly an
  *evidence-canonicality* gate, not pure production-field non-inferiority —
  `ParsedWeeklyPlanSchema` accepts *any* supporting literal span while golden cases score one
  canonical span, so a 4-field-perfect candidate can fail on span choice alone. Predeclared
  diagnostic: compute the candidate's **4-field exact-match rate** alongside (informational).
  Predeclared contingency: if the candidate fails *only* the exactPlanMatchRate leg while the
  4-field diagnostic passes the same 0.05 margin, that is still a gate **FAIL** — no flag flip;
  the recorded remedy is designing a symmetric v2 gate (explicitly relaxing "candidate scorer
  untouched") *before* any re-run. Never post-hoc reinterpretation of a completed run.
- `fieldAccuracy`/latency are informational, not gate-compared.

- Emit via `JSONEncoder` over `VoiceParseEvalMetrics` (all 19 fields required at decode,
  `main.swift:62`; no CodingKeys — JSON keys equal property names).

### D2 — App: identity snapshot + per-call identity lease (additive, inert by default)

`resolveConfiguration()` is private (`AIService.swift:312-362`); its defaulting rules exist
nowhere public; `AIResponse` carries no model identity; **every `generate` call re-resolves
configuration independently, and settings are mutable mid-sweep — a start snapshot plus an
end-of-sweep re-check cannot detect change-away-and-back (Sol F5).** Therefore:

- **Snapshot:** one additive, read-only method on `AIService` sharing `resolveConfiguration()`,
  returning non-secret identity — provider + resolved model id. Pin the artifact format:
  `providerName` ∈ `"openai"` | `"anthropic"` | `"openmodels/<vendor-id>"`; `modelIdentifier` =
  the resolved model id.
- **Lease:** a debug-only assertion hook in `AIService.generate` — inert when no lease is active
  (production always; zero behavior change on the success path). While the runner holds the
  lease, each `generate` call asserts its freshly-resolved (provider, model) equals the leased
  identity; mismatch throws a dedicated abort error → abort class → sweep emits nothing. This is
  the only mechanism that makes "the artifact's identity is what all 180 calls used" *provable*.
- Runner acquires the lease at consent, releases on any terminal path (defer). The sweep also
  aborts on session-epoch change or `aiService` instance change (`AppState` teardown nils it).
- Never expose keys, key presence, or authenticated endpoints.
- Implementer: read `AIService.swift:276-362` and `ProviderDescriptor.swift:68-80` first; mirror
  AIService's existing style. App-hosted tests must prove the lease is inert when inactive and
  aborting when violated.

### D3 — App: baseline runner debug screen + testable controller

A `DebugGate`-gated screen (same gate + Settings embedding as `CloudKitDebugView`; ships dormant
in Release exactly like it). **Extract a testable runner controller** with injected seams —
parse call, identity/lease, clock, lifecycle signals, export sink (Sol F8); production injection
calls unchanged `CloudParseService.parse(transcript:using:)` via `appState.aiService` with the
same session-ready guards `VoicePlanningCoordinator.swift:63,75` uses.

Flow (spec-derived):
1. Load the 60-case corpus from the adapter bundle resource; verify digest; resolve identity
   (D2), acquire lease; show provider/model + call budget (60 × 3 = 180 live calls, plus possible
   transport-level 400 retries) — **explicit consent tap required before any call**.
2. Sweep serially, case-major run-minor. Per run: check `Task.isCancelled` before *and* after the
   call; `ContinuousClock` around `CloudParseService.parse`; success → 4-field rows; throw →
   classify per the Run-validity policy (catch cancellation separately — never recorded).
3. Lifecycle (Sol F6): store the task handle; cancel-and-discard on Cancel tap, view
   disappearance, `scenePhase != .active`, session/epoch change, or lease violation; hold
   `isIdleTimerDisabled` and restore the prior value in `defer`; await sweep-task termination
   before permitting export or restart. (`Task.yield()` is not a cancellation check.)
4. On a *valid* 180/180 completion: score via D1, then export via the `BackupRestoreSection`
   fileExporter pattern, **hash-bound (Sol F7)**:
   - `voice-baseline-metrics.json` — the `VoiceParseEvalMetrics` artifact.
   - `voice-baseline-provenance.json` — sidecar: run ID, **SHA-256 of the exact exported metrics
     bytes**, corpus digest, start/end timestamps (ISO8601), app version/build + repo commit,
     scorer/runner code version, device model, OS version, providerName, modelIdentifier,
     scored-failure category counts. Export both in one user action if the exporter pattern
     allows; otherwise sequential — the hash binds the pair either way.

**Baseline staleness rule (Sol F7 extension):** the baseline is comparable only while (a) the
app's configured provider/model equals the sidecar identity, **and (b) the production-path code
version matches** — `CloudParseService` prompt/extractor, BYOKeyProvider retry/default-model
logic, and scorer version are all identity inputs (hence repo commit + scorer version in the
sidecar). Any change re-stales the file; the sweep must be re-run. This is why the live run is
best deferred until close to the FM candidate eval (per `ai-feature-track-spec.md:68-70`).

### D4 — Adapter: preflight validator (new executable target; existing CLI untouched)

A small macOS-runnable target in the adapter package, run before any
`SimmerSmithBallastEval --live --baseline` invocation. Validates mechanically: metrics file
decodes as `VoiceParseEvalMetrics`; role/corpus constants match `VoiceParseEvalPolicy`; sidecar
present and its SHA-256 matches the exact metrics bytes; prints the sidecar identity + code
versions for the human cross-check against current Settings and HEAD. The gate CLI itself stays
byte-identical.

### Explicitly unchanged (mechanically enforced)

`CloudParseService` (hash-pinned per phase), `VoiceParseEvalPolicy` constants, candidate-side
scoring semantics (proven by the F3 characterization + differential suite), the existing
`SimmerSmithBallastEval` CLI target, `useBallastParse` (existing test re-run per phase),
`ParsedWeeklyPlanSchema`.

## Plan

Standing verify, every phase (Sol F9): `CloudParseService.swift` SHA-256 equals the pinned base
value; `git diff <base>..HEAD` for that file is empty; the existing `useBallastParse == false`
test passes.

- [x] **P1 — adapter: characterization suite → shared-internals refactor → public baseline
  scoring path + coverage validation + differential fixtures.** ✓ 2026-07-16, 58/58 adapter
  tests (36 pre-existing + 8 characterization + 14 baseline/differential). `tier_floor: senior` ·
  `complexity: L`. Verify: `swift test --package-path SimmerSmithBallastAdapter` (36 existing +
  new tests green; sibling ballast checkout required by Package.swift path deps).
- [x] **P2 — AIService identity snapshot + inert-by-default per-call lease.** ✓ 2026-07-16,
  build green + 107/107 app-hosted tests (11 new snapshot/lease tests). `tier_floor:
  senior` · `complexity: M`. Verify: `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj
  -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` **plus
  mandatory app-hosted tests** (lease inert when inactive; abort on violation; snapshot format) —
  mirror the e0a P2 spec §9 ad-hoc app-target suite command (implementer: read that spec first).
- [x] **P3 — runner controller (injected seams) + debug screen + hash-bound export.** ✓
  2026-07-16, build green + 121/121 app-hosted tests (14 new `BaselineRunnerControllerTests`,
  107 pre-existing). `.dataCorrupted` → `emptyOrNonJSONBody`, `.keyNotFound`/
  `.typeMismatch`/`.valueNotFound` → `schemaDecodeFailure` (Foundation's own `DecodingError`
  case split, noted as the classify rationale). No commit-embedding convention found in this
  repo; `repoCommit` falls back to `"app-build-<CFBundleVersion>"` per spec fallback (deviation).
  Simulator smoke: app builds/installs/launches without crash; this sim has no iCloud account so
  RootView's pre-existing "Sign in to iCloud" gate blocks reaching Settings — the exact
  behavioral claims (no call before consent; graceful `.consentUnavailable` degrade; zero network
  calls) are covered by `prepareNeverCallsParseBeforeConsent`/`prepareDegradesGracefullyWithNoService`
  against the same controller code the debug view drives. `tier_floor: senior` · `complexity: L`.
  New app files ⇒ **xcodegen regen required**
  (project.pbxproj is generated; files added without regen silently drop out of the target).
  Verify: P2's build command **plus mandatory app-hosted controller tests** (Sol F8; same
  invocation pattern as P2 — mirror the e0a P2 spec §9 ad-hoc app-target suite command): no call
  before consent; exact case-major 60×3 accounting; cancellation/background/session-epoch/config
  change → no artifact; **`aiService` instance replacement mid-sweep (same resolved identity,
  new object) → abort, no artifact** (the lease's identity-equality check alone cannot catch
  this); Run-validity classification correct incl. terminal-400 → abort; idle-timer restored;
  exported metrics decode as `VoiceParseEvalMetrics`; sidecar hash binds the exported bytes.
  Plus simulator smoke: no-key/no-session degrades gracefully, consent gate shows, no network
  call.
- [x] **P4 — adapter preflight validator target + tests.** ✓ 2026-07-16, 71/71 adapter tests
  (13 new, every ValidationError case) + built binary smoke-tested both directions.
  `tier_floor: junior` ·
  `complexity: S`. Verify: `swift test --package-path SimmerSmithBallastAdapter` (validator
  logic covered; existing CLI target byte-identical).
- [ ] **P5 — live baseline sweep (HUMAN; separately gated).** Explicit user spend consent
  in-app; device run; export both files; run D4 preflight; attach evidence to `simmersmith-zyp`.
  `[?]` human — never run headlessly, never absorbed into P1–P4 verification.

## Landmines

- `.beads/` is git-excluded: zyp/96j constraints are inlined here on purpose — do not rely on
  bead IDs traveling with a clone.
- `AIService` is `@MainActor`; the sweep serializes on the main actor. Keep the UI responsive;
  remember `Task.yield()` is not a cancellation check — use explicit `Task.isCancelled` checks.
- Settings can change away-and-back between two snapshots — only the per-call lease (D2) closes
  this; do not "simplify" it away during implementation.
- The lease must be un-engageable outside the runner (debug screen owns it; assert single
  ownership). Inert-by-default is a binding property — prove it with a test.
- No 429/5xx retry exists anywhere in the production chain — do not add any; those failures are
  abort-class, not data.
- URLSession timeouts in the chain are 180s/300s; timeouts are abort-class, so a hung provider
  ends the sweep rather than stretching it toward the ~15h worst case Sol computed.
- `simmersmith-96j` (cloud-leg characterization) is adjacent but separate; this runner must not
  morph into an `AIServiceParseProvider` replacement effort.

## Review

- 2026-07-16 — recon: 5-reader + completeness-critic workflow (Claude); all load-bearing claims
  file:line-verified; critic caught the LanguageProvider-shim decode trap pre-spec.
- 2026-07-16 — **Sol adversarial review** (`openai-codex/gpt-5.6-sol`, thinking=max, 16m14s,
  clean exit): **NOT-CLEAR** — 2 BLOCKER, 6 MAJOR, 1 MINOR (8 CONFIRMED, 1 SPECULATIVE). All
  folded into this revision: F1→Run-validity policy; F2→evidence-canonicality declaration +
  4-field diagnostic + FAIL contingency; F3→characterization-first + differential fixtures;
  F4→structural coverage validation, transcript-free samples; F5→per-call identity lease;
  F6→lifecycle/cancellation semantics; F7→hash-bound sidecar + D4 preflight validator +
  code-version staleness; F8→testable controller + mandatory app-hosted tests; F9→mechanical
  unchanged-constraint checks per phase.
