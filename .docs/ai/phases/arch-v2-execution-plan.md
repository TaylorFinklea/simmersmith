# arch-v2 execution plan — handoff to Opus (Fable, 2026-07-02)

The lane map for implementing the arch-v2 + remaining P1/P2 beads. The beads are self-contained;
THIS document adds what the queue can't express: file-collision lanes, execution order, and the
non-negotiables. Read `decisions.md` 2026-07-02 for the why; `bd show <id>` for each what.

## Non-negotiables (delegation-method invariants)

- One writer per file at a time. The lanes below are the collision map — do not parallelize within
  a lane, ever. Across lanes is safe (files disjoint; SwiftPM serializes on the shared .build lock —
  expected, do not use --scratch-path; disk filled once already).
- Every lane gets an independent adversarial verify before commit (the v2 review confirmed defects
  in day-old fleet code — new code gets no free pass).
- Orchestrator backstop-verifies personally: read the diff, run `swift test --package-path
  SimmerSmithCloudKit` + `--package-path SimmerSmithKit` + xcodebuild (fresh derivedDataPath after
  any xcodegen), commit per lane, close beads with hashes, log the scorecard.
- Sonnet session limits reset on 5-hour windows — launch big fleets just after a reset; resume
  (`resumeFromRunId`) re-runs only dead agents.
- pbxproj stays unstaged unless project.yml changed (then commit the regen with it).

## Lane map (P1 wave)

**Lane A — engine core (STRICTLY SEQUENTIAL — all touch HouseholdSyncEngine.swift and/or
HouseholdSession.swift init/wiring):**
1. `r8q` interim token reset (read the LEAD DESIGN CLARIFICATION note first — the naive reading
   is a trap) — touches HouseholdSession.init.
2. `c7r` merger-at-init + zoneEnsured lock + adopt-vs-mint audit — same init/wiring territory;
   doing r8q first keeps the diff surface honest.
3. `6ce` rebase updatedAt-LWW — handleFailedSave. Fallback chain: updatedAt → createdAt →
   current behavior (weekChangeBatch/Event + eventAttendee lack updatedAt).
4. `dab` failed-save classification (quota et al) — same switch; MUST land after 6ce (same hunks).
Lane A output feeds `qrt` (sync-status UI, app-side files — may start once dab's engine callback
shape is fixed, in parallel with A4's tail).

**Lane B — `9zf` RepairScheduler isolation + collapse logging.** Package file disjoint from Lane A.
Parallel-safe with A.

**Lane C — `eky` meal-merge choke point.** WeekRepository + MealMergeResolver + AppState+Weeks.
Prefer the repo-boundary fold (one choke point); preserve the tool/voice explicit-clear semantics.
Parallel-safe with A/B. `pr9` (CKRecord defensive copies) follows C in the SAME lane —
HouseholdLocalStore.record(for:) copies interact with every repo's mutate path; do not interleave.

**Lane D — assistant surfaces, SEQUENTIAL:** `7pr` (Smith tab + coordinator routing) then `962`
(Create-with-AI/Manage-sides → AIService). Both orbit WeekView/AIAssistant files.

**Lane E — `5w8` privacy-policy rewrite.** docs/ only; fully parallel. Acceptance includes a
claims-vs-code checklist in the close note; the ASC nutrition-label half is the USER's.

**Lane F — `9wr` PUBLIC grant revoke.** Source edit + cktool validate is agent work; the
PRODUCTION deploy is the USER's Dashboard op (schema is additive-only; this is a permission
change — verify a client write is rejected afterward).

## P2 wave (after P1 lanes land)

`e0a` store persistence (retires r8q's hack; read its LEAD VALUE FRAMING note — test the
offline-edit-survives-relaunch scenario) · `qrt` if not already done · `yqm` (+ account-change
pending-edit scope) · `lwi` share-accept warning · `mm1` onboarding delete · `ebu` grocery archive
load · `0g5` MetricKit · `79y` Logger/OSLogStore · then the SP-D children (990.4.x memories per
spec, 990.5.x ingredients per spec) and the retirement chain 990.8→.12 as ports complete.

## Device/user gates outstanding (do not loop headlessly)

Build-147 product test (hdeck `p1-milestone-product-test`) · 3sf streaming gate (same build) ·
`9wr` prod deploy · `cnx` Reminders round-trip · push `main` (~20 commits ahead; activates CI —
after pushing, confirm ci.yml includes the app build job per the l00 note).

## What NOT to do

- Don't re-review before implementing — two independent reviews converged; the queue IS the
  consensus. Implement.
- Don't refactor AppState/god-object or add protocol seams opportunistically — that's the
  explicit post-launch track.
- Don't touch the dormant GLM/Kimi/MiniMax vendor code (waits for the OpenRouter device gate).
- Don't create new CloudKit record types without a Lead-signed spec (additive-only, irreversible;
  990.4's spec is the template).
