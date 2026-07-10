# AI & product feature track — post-launch sequencing

> Status: DRAFT (Fable, 2026-07-09) — panel review pending. Post-launch. Groups the loose AI
> beads (exc, 2d1, a0a, 3sf, zyp, 95h, h2h, nt2, fbn, 3pa) into three waves with the
> dependency that governs them, and settles the one real design question (onboarding).

## The governing constraint

Every cloud AI call needs a key the user supplied. Keyless users have **no assistant, no
week-gen, no voice parse** — so every feature in this track is invisible to them until either
(a) the credits gateway ships (`credits-gateway-spec.md`), or (b) iOS 27 AFM makes on-device
the free floor (bead 95h). **Wave ordering follows that gate**, not feature appeal: the tool
surface and the onboarding interview are worth more per unit of work AFTER a keyless user can
reach them. Spending Wave-2 effort before the gateway lands buys polish only current
BYO-key users (Taylor + Savanne) will see.

## Wave 1 — hygiene (no dependency; dispatchable now, cheapest tiers)

Four bounded beads that fix things that are currently *lies or dead code*, not features:

- **`nt2`** (junior · S) — AssistantSystemPrompt still implies full-set meal edits after enx
  made `weeks_update_meals` merge-only; also teach the model to echo `day_name`/`slot` casing
  verbatim (the merge key is case-sensitive). A prompt-truth bug with a data-loss-shaped tail.
- **`fbn`** (senior · S) — the assistant-done Settings toggle is wired to nothing since Fly's
  APNs died. **Decision (Fable): fire a LOCAL notification** (`UNNotificationRequest`) when a
  backgrounded assistant turn completes — do not delete the toggle. Rationale: the app already
  owns the exact pattern (M20's cook-timer local notification), the user-visible promise is
  already made, and a local notification needs no server, matching ADR-1's "push becomes local
  notifications." Remove the toggle only if implementation reveals the turn cannot outlive
  backgrounding (verify first, then escalate).
- **`3pa`** (junior · S) — add `AIFeature.vision`; stop reusing `.companionDraft`. Pure
  correctness for tier routing; blocks nothing but pollutes routing telemetry forever if left.
- **`h2h`** (senior · M) — publish catalog macros so nutrition aggregation is complete.
  Sequence AFTER `990.5.3` (nutrition-match verify-then-drop) so the two don't argue about the
  same code; 990.5.3 may prove h2h is already satisfied by the live catalog-macros path.

Verify per bead: existing suites + app build (nt2/3pa are one-file edits; ideal ralph/pi loop
material — command-verifiable, at/below their tier ceiling).

## Wave 2 — assistant depth (gated on the gateway OR accepted as BYO-key-only polish)

- **`3sf`** (senior · M) — token streaming on the on-device/CloudKit assistant path. The
  transport work already landed (SSELineSplitter, the multi-block separator fix); this is the
  remaining app-side wiring + its device gate. Cheapest of the wave; may run early.
- **`2d1`** (senior · L, **spec first — lead**) — grow the on-device assistant from **12 tools
  (measured: `Data/ToolRegistry.swift`, 547 lines) toward the 49-tool Fly-era surface**.
  This is NOT a mechanical port: the Fly registry's 49 tools included server-only capabilities
  (pricing, admin, push) that ADR-1/ADR-2 killed. **Required pre-work**: an inventory bead that
  classifies all 49 into port / drop / redesign, with the drops justified against the current
  architecture. Only then fan out ports in file-disjoint batches. The 2d1 bead as written
  ("grow toward 49") would send an implementer porting dead capabilities — fix the bead before
  dispatching it.
- **`a0a`** (senior · M) — web-search + exports tools. Web search needs a provider-side tool
  (OpenAI Responses / Anthropic web_search) — descriptor-dependent, so it lands only for
  vendors that support it; the tool must degrade honestly (not silently absent) on vendors that
  don't. Exports (share a week/list) is pure local capability, no provider dependency — split
  the bead if the two diverge in review.
- **Dependency**: `2d1` and `a0a` both widen the assistant's write surface. If the structural
  track's **S6 (ToolRegistry capability boundary)** is in flight, S6 lands FIRST — otherwise
  each new tool is another blanket-AppState consumer to retrofit later.

## Wave 3 — on-device & onboarding (iOS-27 / product-gated)

- **`95h`** (lead · M) — measure AFM 3 / PCC at iOS 27 GA. Blocks the free-tier story; a real
  measurement (not a vibe) decides whether keyless users get on-device week-gen or must hit
  the gateway. Keep parked until GA, then it becomes the highest-value bead in this track.
- **`zyp`** (senior · M) — flip `OnDeviceParseService.isEnabled` once parse quality is proven.
  **Dependency the bead doesn't state**: quality is judged against the *currently configured
  cloud model* — with the provider swap (Ollama Cloud / NeuralWatt) that baseline just changed,
  so any pre-swap quality note is stale. Re-baseline before flipping.
- **`exc` — AI preference interview** (lead spec · then senior · L). The one genuine design
  question in this track; my scoping:

### exc: onboarding preference interview — scoping decision

The orphaned Fly-era interview was deleted (mm1); nothing reads its outputs. The temptation is
to rebuild "a chat that asks 20 questions." **Design position: don't.** Three grounded reasons:
(1) a keyless user cannot run a conversational interview at all — it would be the first thing a
new user hits and the first thing that fails; (2) the app already *has* a preference-learning
loop (`PreferenceSignal` scores, ingredient avoid/allergy flags, meal feedback) that beats a
cold interview's data quality; (3) the interview's real job is **cold-start**, and cold-start
needs ~5 facts, not a conversation.

Proposed shape (to be specced under exc, panel-reviewed before beads):
- **Deterministic, keyless-safe onboarding**: a 4-screen non-AI flow capturing household size,
  hard avoids/allergies (writes real `IngredientPreference` rows — the highest-value, highest-
  risk facts), cuisines liked, and week-start/timezone. Zero AI calls; works with no key.
- **Optional AI deepening, offered later**, not at first run: once the user has a key or the
  gateway grants credits, offer "let the assistant learn your tastes" — which is just a
  pre-seeded assistant thread using the EXISTING tool loop, writing to the EXISTING preference
  tables. No new persistence, no new interview engine, no new record types.
- Success metric to state in the spec: a first-run user with no key can reach a plannable week
  (manual or on-device) without hitting an AI dead-end. That is the same 4.2-mitigation path
  App Review takes.

## Fan-out note (why this ordering serves cheap dispatch)

Wave 1 is four command-verifiable, single-file-ish beads at junior/senior-S — ralph/pi loop
material. Wave 2 needs S6 or a hand-written collision map. Wave 3 is lead-specced. Any agent
picking from this track should confirm its wave's gate is open before starting.
