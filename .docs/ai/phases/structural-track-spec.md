# Structural track (z69) — seams, decomposition, testability

> Status: DRAFT (Fable, 2026-07-09) — panel review pending. Post-launch; nothing here blocks
> submission and none of it may be pulled forward opportunistically (standing rule). Realizes
> the z69 umbrella both arch reviews agreed on. tier_floor per phase below; epic stays lead/XL.

## 1. Why (measured, not vibes)

`AppState` is 8,228 lines across 19 extension files — a `@MainActor @Observable` composition
root that also owns session lifecycle, all 11 repository references, every domain's mutation
logic, SSE decoding types, and Fly-era residue. Consequences, all evidenced this cycle:
session-lifecycle bugs recur where ownership is diffuse (0gf boot races, v89 mid-wire
teardown, glw scheduler-outlives-teardown); nothing app-side is unit-testable (zero app-target
tests — the qrt/ioj sync-status POLICY bugs shipped untested because only package code has
tests); and every cheap-model dispatch must be handed a hand-written file-ownership map
because domain boundaries exist only by convention.

The track's goal is NOT aesthetics: it is (a) making lifecycle bugs structurally hard,
(b) making app-target logic testable by command, and (c) making domains independently
dispatchable to Senior/Junior models without collision maps.

## 2. Design rules (apply to every phase)

- **Behavior-preserving.** Every phase is a pure refactor; any behavior change found mid-work
  stops the phase and files a bead instead.
- **Independently shippable.** Each phase lands, builds, and passes suites on its own; no
  long-lived branch.
- **Facade stays.** Views keep reading `appState.*` — extractions move OWNERSHIP, and the
  façade delegates. View-layer migration is explicitly out of scope (a later, optional wave).
- **One writer per phase**; phases are sequenced to avoid file overlap with the launch queue.

## 3. Phases

### S1 — HouseholdSessionCoordinator (extract the mislabeled bootstrap) · senior · L
The session lifecycle currently lives in `AppState+Recipes` (ensure/teardown), `AppState+Sharing`
(adopt/participant boot), and loose AppState fields (`sessionBootQueue`, `sessionBootEpoch`,
`householdSession`, 11 repo vars). Extract ONE `@MainActor @Observable`
`HouseholdSessionCoordinator` owning: session boot (both entry points), the FIFO boot queue +
epoch, repo construction/wiring/teardown, repair-scheduler lifecycle (post-glw), and the
launch-phase state. AppState holds exactly one reference to it and delegates. The glw/0gf/v89
bug class gets one auditable home; v89's mid-wire teardown window becomes fixable INSIDE the
coordinator rather than across three files.
Verify: both package suites + app build; a grep gate — `ensureHouseholdSession|sessionBootEpoch`
appear only inside the coordinator file (+ façade forwarders).

### S2 — Repository protocol seams + fakes · senior · M
Protocols for the repositories AppState consumes (start with the four the assistant/tools
touch: Week, Grocery, Recipe, Event; the rest follow mechanically). Coordinator fields type to
the protocols; concrete types conform with zero body changes. Add `SimmerSmithTestSupport`
(app-target group or a Kit product — implementer picks after reading how xcodegen lays out
targets in project.yml) holding in-memory fakes that satisfy the protocols.
Verify: app build + a smoke test constructing each fake.

### S3 — App-target test coverage · senior · M

**Correction (2026-07-09, found while implementing `b9z`): the host already exists.**
`project.yml:61` declares a `SimmerSmithTests` target, and it already holds
`SimmerSmithTests.swift` + `ToolRegistryDecodeTests.swift` with an established
`@testable import SimmerSmith` pattern. An earlier draft of this spec asserted "zero app-target
tests"; that was wrong, and the wrong premise nearly justified an XL phase to build something
that ships today. The real gap is **usage, not existence** — the `qrt`/`ioj` policy bugs shipped
untested because nobody *wrote* the test, not because they couldn't.

So S3 is smaller than it looked:
1. Confirm the target runs headless and make that command a bead-level `verify_cmd`:
   `xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=<sim-UDID> -only-testing:SimmerSmithTests`
2. Seed the coverage the recent bug wave proves is missing: `SyncStatusCenter` clear policy
   (`ioj` — see bead `zrr`), coordinator boot-epoch staleness (after S1), `ToolRegistry`
   dispatch/branching (extend the existing file).
3. The entitled-host PrivatePlane tests (bead `aeu`) ride this scheme.

Verify: the `xcodebuild test` command exits 0 with the seed tests green.

### S4 — Domain extraction wave (repeatable; one bead per domain) · senior · M each
With seams + tests in place, extract per-domain logic from `AppState+X` into domain services
consuming repo protocols: Weeks (651), Assistant (610), Events (512), Grocery (370),
Recipes-domain (what remains of the 2,004 after S1 removed lifecycle), Reminders (441),
AI-settings (402). Pattern per bead: move functions, façade delegates, add tests for the
moved logic against fakes, zero view changes. These beads are the fan-out payoff — after S1–S3
they are safely dispatchable to cheap Seniors WITHOUT hand-written collision maps (each owns
`AppState+X.swift` + its new service file).
Verify per bead: suites + app build + the S3 test target green.

### S5 — CloudKitDebugView modularization · junior · M
Both reviews flagged it; pure mechanical split of the debug console into per-check files.
Verify: app build; DEBUG-only surface unchanged.

### S6 — ToolRegistry capability boundary · senior · M
The reviews' residual testability concern: tools declare a capability (read/write × domain)
instead of receiving blanket AppState access. Registry enforces; tests assert the assistant's
write surface is exactly the declared set. This is also the pre-work that makes a future
"assistant safety audit" a table lookup instead of a code hunt.
Verify: S3 target's registry tests + app build.

## 4. Sequencing & interaction with other tracks

S1 → S2 → S3 strictly ordered; S4 beads free-order after S3; S5 anytime; S6 after S3.
Do not start S1 while any launch-gate engine bead is open (it moves the same files glw/0gf
touched — land those first). The gateway track (credits-gateway-spec.md) is independent —
gw-4/gw-5 touch SubscriptionStore/AIService, not the session files; if scheduled in the same
window as S4's AI-settings bead, serialize those two.

## 5. Non-goals

View-layer rearchitecture (views keep AppState). Swift 6 strict-concurrency migration
(separate decision). Moving repositories into a package (they are @MainActor UI-adjacent;
packaging buys nothing testability that S2's protocols don't). Renaming for its own sake.
