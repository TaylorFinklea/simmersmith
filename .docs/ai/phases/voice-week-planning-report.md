# Voice Week-Planning — Report

**Status:** built + shipped to TestFlight (build 137); on-device human gate pending. 2026-06-29 (Opus).
Spec: `voice-week-planning-spec.md`. Decisions: `decisions.md` (2026-06-29).

## What shipped

Talk-out-your-week: hit the Week-tab mic (or the assistant composer mic), speak the week, review the proposed
meals, apply. Four layers, ~80% on-device:

1. **Transcribe** — `DictationService` (on-device `SFSpeechRecognizer`, accumulates the transcript across the
   ~50s buffer cap; a generation counter guards stale callbacks).
2. **Parse** — `OnDeviceParseService` (FoundationModels `@Generable`, SDK-verified API) → `ParsedWeeklyPlan`;
   `CloudParseService` fallback (one-shot `AIService.generate` structured seam, reusing the shipping
   `BYOKeyProvider.extractJSONObject` for `<think>`/fence-robust JSON) for ineligible hardware / on-device error.
3. **Resolve** — `VoicePlanResolver` (pure, host-tested): UTC `mealDate` math, best-match-else-free-text against
   the library, intents → app conventions (eatOut→"Eating Out", leftovers→"<dish> Leftovers", skip→omit),
   relative days dropped if outside the planned week.
4. **Review + apply** — `VoicePlanReviewView` (review-before-apply; Apply flips `approved=true`) → existing
   `saveWeekMeals` (grocery regen + CloudKit). `VoicePlanningCoordinator` drives the flow; entry via a Week-tab
   `VoicePlanningButton` + a `ComposerMicButton` in the assistant.

Canonical plain `ParsedWeeklyPlan`/resolver/availability live in **SimmerSmithKit** (host-testable); the
app-target `@Generable GenerableWeeklyPlan` is a thin adapter that maps into them.

## Process

Brainstorm (4 user decisions: full hybrid · review-first · best-match-else-free-text · Week+composer entries)
→ SDK-header-verified spec workflow (critique caught the DayKey UTC landmine, the String-vs-Date weekStart, the
wrong cloud seam, the ineligible-HW dead-end — all folded in) → Opus implemented T0-T10 → 5-dimension adversarial
review workflow (8 confirmed findings: 1 critical approved-flag bug + 7 important/minor, all fixed) → shipped.

## Verification

- **Headless (run): 12 SimmerSmithKit tests** — resolver UTC mealDate/match/intents/relative-out-of-week +
  contract round-trip; availability decision table.
- **Build:** app compiles clean (iphoneos26, `@Generable` + FoundationModels).
- **API:** Speech + FoundationModels verified against the real iOS 26 SDK `.swiftinterface`.
- **Device-gated (the harness-deck gate):** live on-device transcription, the `@Generable` parse engaging on
  eligible hardware, real dish-name transcription quality, cloud fallback. No Apple sample for the on-device
  transcribe→parse pipeline — the gate is the proof. Report: `simmersmith/voice-week-planning-device-test`.

## Deferred / follow-ups

- **SpeechTranscriber engine (v1.1)** — iOS 26's newer streaming on-device API (longer dictation, native
  partials). v1 ships SFSpeech (works on every iOS 26 device); the availability resolver already accounts for it.
- Streaming live-parse preview; composer-mic auto-routing into the review flow; day/slot moves in the review
  screen; multi-locale. All listed out-of-scope in the spec §13.
- Pre-existing: a SwiftPM test-process *exit* flake (signal 5; suite passes) unrelated to this work.
