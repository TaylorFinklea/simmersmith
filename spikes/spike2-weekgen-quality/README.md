# Spike 2 — Week-gen quality (AFM 3 / PCC vs gpt-5.5 + Claude)

**Throwaway de-risking spike.** Spec + report:
`.docs/ai/phases/cloudkit-migration-spikes-{spec,report}.md`.

## What it answers
Is on-device AFM 3 (and/or Private Cloud Compute) good enough at full-week
planning to be the free default, or is week-gen a tier that needs a cloud
frontier model (BYO-key / credits)?

## Status (2026-06-15)
**Run deferred to iOS 27 GA** (this machine is Xcode 26 / iOS 26 = first-gen
Foundation Models only). Built now and verified: the **corpus + rubric + tests** —
the durable, provider-agnostic core. The provider calls are stubs to wire at GA.

## Built now (runnable today)
- `models.py` — `PlanningContext` / `WeekPlan` shapes mirroring production.
- `corpus.py` — the **8-context test corpus** (2 goals, ≥2 allergy sets, varied
  prefs, history-heavy case).
- `rubric.py` — the **scorer**: allergy violations (hard fail), avoid hits,
  reuse-cap (≤3), history dedup, variety, ±15% macro drift, latency.
- `test_rubric.py` — 13 unit tests. Run: `python3 -m unittest test_rubric`

## Wire at GA
- `backends.py` — `OpenAIBackend` (gpt-5.5), `AnthropicBackend` (Claude),
  `AFM3OnDeviceBackend`, `PCCBackend`. All raise `NotImplementedError` with a
  GA-wiring note. Lift the prompt from
  `app/services/week_planner.py::_build_system_prompt` (+ `gather_planning_context`)
  — do not paraphrase it. On-device backends emit plan JSON from a Swift
  FoundationModels tool; `plan_from_json` ingests it.
- `runner.py` — corpus × backends → `format_table` → paste into the report.

## Verdict
TBD at GA. Hard gate: any allergy violation fails that tier for week-gen.
