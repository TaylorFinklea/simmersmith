# P8 — App-Owned Cloud-Baseline Runner: Implementation Report (P1–P4)

**Status:** P1–P4 complete on branch `p8-baseline-runner`, 2026-07-16. P5 (live 180-call sweep)
remains HUMAN-gated on explicit spend consent — never run headlessly. Branch is unmerged;
merge timing is the user's call (the debug screen ships dormant behind `DebugGate`, same as
`CloudKitDebugView`, but the e0a launch track is active on main).

## Delivered (one commit per phase; base `12ff8c5`, pins in `p8-cloud-baseline-runner-pins.md`)

- **P1 (`6e26035`)** — adapter public baseline scoring path, characterization-first:
  8 tests pin the private candidate scorer via the public runner surface, then the shared-
  primitives hoist (`VoiceParseScoringPrimitives`, pure delegation), then `VoiceParseBaselineEval`
  (transcript-free `caseID`/`runIndex`/outcome samples; digest + structural 60×3 coverage
  validation; baseline-role 4-field semantics per spec D1) + differential tests reusing the
  characterization fixtures verbatim. 58/58.
- **shared schema (`89ee640`)** — `VoiceBaselineProvenance` Codable + `scoringVersion`
  (Lead-authored so P3/P4 could not drift on the sidecar shape).
- **P2 (`d4192ca`)** — `AIServiceIdentity` snapshot sharing private `resolveConfiguration()`;
  inert-by-default single-owner per-call identity lease asserted inside `generate()`
  (dedicated abort error on mid-sweep drift, incl. change-away-and-back). 11 new app-hosted
  tests; 107/107.
- **P3 (`470867c`)** — `BaselineRunnerController` (@MainActor @Observable, 5 injected seams) +
  `BaselineRunnerDebugView` behind `DebugGate` in Settings' developer section. Consent gate
  before any call; per-call `ObjectIdentifier` + session-epoch checks; fail-closed
  classification (only `DecodingError` scores: `.dataCorrupted` → emptyOrNonJSONBody, else
  schemaDecodeFailure); cancel on tap/disappear/scenePhase, never recorded as data; lease +
  prior idle-timer restored in `defer`; export only on valid 180/180 — metrics JSON + SHA-256-
  bound provenance sidecar, two sequential fileExporter presentations (BackupDocument reuse).
  14 new app-hosted tests; 121/121.
- **P4** — `VoiceBaselinePreflightValidator` core in the library + thin `VoiceBaselinePreflight`
  executable target. Validates metrics decode/role/policy constants, sidecar decode, metrics-
  bytes SHA-256 binding, corpus-digest agreement, scorer-version match; prints identity for the
  human config cross-check. 13 new tests (every `ValidationError` case); binary smoke-tested
  both directions. 71/71 adapter total.

## Verification evidence

- `swift test --package-path SimmerSmithBallastAdapter` → 71/71 (36 pre-existing + 35 new).
- `xcodebuild build … CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED.
- App-hosted suite (`-only-testing:SimmerSmithTests`, e0a §9 pattern) → 121/121, incl.
  `useBallastParse == false`.
- `CloudParseService.swift` SHA-256 = pinned `40575d47…d3b7` after every phase; diff vs base
  empty. `VoiceParseEvalPolicy`, existing eval CLI sources, `ParsedWeeklyPlanSchema` untouched.
- Simulator smoke: app launches clean; the sim has no iCloud account so the pre-existing
  sign-in gate blocks UI click-through to Settings — consent/no-call behavior is instead proven
  by controller unit tests (`prepareNeverCallsParseBeforeConsent`,
  `prepareDegradesGracefullyWithNoService`). Full-UI smoke lands with P5's device run.

## Reviewed judgment calls (Lead-approved)

- Fixture `[A,B]` vs spec's illustrative `[A,B,B]`: duplicate predicted signatures are
  unreachable on the candidate path (`ParsedWeeklyPlanSchema` rejects duplicate day+slot);
  the substitute exercises the same min-capping path. Documented inline.
- `DecodingError` case split as the two scored categories (extract never throws; decode is the
  only throw point) — principled, documented in `classify(_:)`.
- `repoCommit` = `app-build-<CFBundleVersion>` (no commit-embedding convention exists in the
  repo); acceptable because the sidecar's app version/build identifies the release commit.
- P4's Package.swift gains only an `.executableTarget` (no product entry; SwiftPM builds it).

## P5 — how to run the live sweep (when the user chooses to)

1. On a real device with the production config: Settings → developer section (DebugGate) →
   Baseline sweep. Consent screen shows resolved provider/model + 180-call budget.
2. Valid 180/180 completion → export `voice-baseline-metrics.json` +
   `voice-baseline-provenance.json`.
3. Preflight: `swift run --package-path SimmerSmithBallastAdapter VoiceBaselinePreflight
   <metrics> <sidecar>`; cross-check printed identity vs current Settings and HEAD.
4. Gate: `swift run --package-path SimmerSmithBallastAdapter SimmerSmithBallastEval --live
   --baseline <metrics>` on Apple-Intelligence hardware; attach evidence to `simmersmith-zyp`.
   A provider/model config change or production-path code change re-stales the baseline.
