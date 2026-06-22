# SP-C — AI track, slice AI-1: Infrastructure + Week generation

> Design spec. Approved 2026-06-21. First AI slice. Model strategy (decided): **BYO-key now**
> (OpenAI/Anthropic, key in Keychain, called direct from device); on-device AFM deferred to iOS 27.
> Full AI parity is the goal (assistant + images included) but decomposed — this slice is infra + week-gen.

## 0. Goal + scope
Make the SP-A `AIProviderKit` stubs real and bring back **week generation** (the core meal-planning AI),
running entirely from the device against the user's own cloud key. No Fly.

**IN:** real `BYOKeyProvider` (OpenAI + Anthropic, structured output); the BYO-key UX (Settings → Keychain);
an app-layer `AIService` routing via the SP-A `ProviderRouter`; the **week-gen prompt ported to Swift** +
on-device context gathering (from CloudKit + the private plane) + structured-output parse + the Spike-2
allergy hard-gate; un-gate the "generate week" affordance.
**OUT (later AI slices):** recipe AI (AI-2), nutrition/event AI (AI-3), AI images (AI-4), the assistant (AI-5).
On-device tier stays stubbed (iOS 27).

## 1. What SP-A built (make real, don't redesign)
`SimmerSmithCloudKit/Sources/AIProviderKit/`: `AIProvider` protocol (+ `AIFeature`, `AITier`
[.onDevice/.cloudBYOKey], `CloudModel`, `AIRequest`/`AIResponse`, `AIError`); `ProviderRouter.tier(for:)`
(heavy→cloud-BYO-key, light→on-device, on-device-heavy gated); `KeyStore`/`KeychainKeyStore` (keys in
Keychain, NEVER CloudKit — SP-A §7.1); `OnDeviceProvider` (stub, iOS 27); `BYOKeyProvider` (stub → make
real here); `CreditsGatewayProvider` (stub, unused). 5 `ProviderSelection` tests cover the routing.

## 2. Components to build
| Component | New/real | Responsibility |
|---|---|---|
| **`BYOKeyProvider` (real)** | real (AIProviderKit) | direct HTTPS to OpenAI (chat completions) + Anthropic (messages) with the Keychain key; **structured output** (OpenAI `response_format: json_schema` or tool-use; Anthropic tool-use) so results parse deterministically; map provider errors → `AIError`. |
| `AIService` | new (app Data/) | for an `AIFeature` + an `AIRequest`, resolve via `ProviderRouter` + the configured CloudModel + `KeychainKeyStore`, call the provider, return the parsed result. The single seam every AppState AI method uses. |
| BYO-key UX | modify (Settings) | the existing AI section (provider/model pickers + key field) rewired: provider/model → private-plane `PrivateProfileSetting` (or local); the **API key → KeychainKeyStore** (`saveAISettings` no longer writes the key to Fly/CloudKit). A "Test key" button (a cheap models-list/ping call). Surface "no key set" state. |
| **Week-gen prompt library** | new (port) | port `app/services/week_planner.py` `_build_system_prompt` (+ the user/context prompt) to Swift string-builders — FIDELITY to the server is the bar. Plus the **planning-context gather** (`gather_planning_context`): pantry staples (PantryRepository), dietary goal + ingredient prefs (Profile/PreferenceRepository), recent meals/recipe library (Recipe/WeekRepository) — from CloudKit + the private plane, NOT Fly. |
| Week-gen feature | new (app) | `generateWeek(...)`: build context → prompt → `AIService` (structured 21-meal schema) → parse → apply allergy hard-gate → `WeekRepository.saveWeekMeals`. Replaces the `// AI TRACK` stub in `AppState+Weeks.generateWeekFromAI`. Un-gate the "generate week" affordance (the sparkle FAB / the week-gen entry that currently routes to coming-soon). |

## 3. The week-gen prompt port + structured output (the #1 risk)
- **Read the authority:** `app/services/week_planner.py` (`_build_system_prompt`, the meal-plan instructions,
  the constraint handling: allergies as HARD constraints, macro targets ±tolerance, variety, recipe-reuse
  cap, dedup, the response shape) + `gather_planning_context`. Port the prompt-builder + the context gather
  to Swift, matching behavior — a degraded prompt produces worse plans.
- **Structured output:** define the meal-plan JSON schema (days × slots × {recipeName, recipeId?, servings,
  notes, …} matching what `saveWeekMeals` needs) and request it via the provider's structured-output mode so
  parsing is deterministic (no brittle free-text scraping).
- **Allergy hard-gate (Spike-2 invariant):** after parse, validate the plan against the user's allergy
  preferences (choiceMode == "allergy"); if ANY meal's ingredients violate an allergy, FAIL the generation
  with a clear error — never surface an unsafe plan. Headless-test this against a violating fixture.

## 4. Error handling
- No key configured → `AIError`/a clear UI prompt "add your OpenAI/Anthropic key in Settings" (not a crash;
  the "generate week" button explains it).
- Provider error (401/rate-limit/5xx) → surfaced with a retry; never a bare crash.
- Malformed/parse-fail output → reject + retry once; if still bad, a clear "AI returned an unexpected
  response" error.
- Allergy violation → fail-closed (§3).

## 5. Verification
- **Headless:** the prompt-builder produces the expected structure for a known context fixture; the
  structured-output parser round-trips a sample provider response → the meal schema; the allergy hard-gate
  rejects a violating plan + passes a clean one; the `BYOKeyProvider` request-builder emits the correct
  OpenAI + Anthropic request bodies (mock the HTTP — don't call the real API in tests). The SP-A routing
  tests stay green.
- **On-device (TestFlight):** paste a real OpenAI/Anthropic key in Settings → "Test key" succeeds →
  "generate week" produces a valid 21-meal plan honoring the dietary goal + avoiding allergens, saved to the
  week on CloudKit. A key-not-set state shows the prompt, not a crash.

## 6. Risks
- **Prompt fidelity** — the central risk: the ported prompt must match `week_planner.py` so plans are as good
  as today's. Reviews scrutinize the port against the Python.
- **Structured output across two providers** — OpenAI vs Anthropic have different structured-output mechanics;
  the BYOKeyProvider must handle both. Test both request shapes.
- **Context from CloudKit/private plane** — gather pantry/goal/prefs/recipes from the new stores, not Fly;
  a missing piece (e.g. empty pantry) must degrade gracefully (the server handled empties).
- **The API key must NEVER reach CloudKit** — Keychain only (SP-A §7.1). The migration/profile code must not
  carry it.
- **No new CloudKit record types** this slice (week-gen writes existing Week/WeekMeal records) → no schema
  deploy.
