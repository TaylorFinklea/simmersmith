# Launch runbook — the gates between here and the App Store (Fable, 2026-07-02)

The definition of "ready for prod." The acting Lead maintains this (Sonnet 5 while Opus/Fable are
unavailable — see the `lead-succession` bd memory): check gates off as beads close, never
reorder without recording why in decisions.md. Companion to `arch-v2-execution-plan.md` (the HOW);
this is the WHEN-ARE-WE-DONE.

**Standing decision that unlocks timing: launch does NOT wait for Fly's deletion.** The retirement
chain (990.8–.12) can finish post-launch. Launch requires only: (a) no user-visible feature calls
Fly (Gate 2), and (b) nothing user-facing references fly.dev URLs (Gate 3). The server can idle,
paid-for and ignored, through submission.

## Gate 0 — foundations (user, this week)
- [ ] Push `main` (bead tjc; ~22 commits ahead). Confirms CI live from day one of Opus work —
      after pushing, verify ci.yml runs all three jobs incl. the app build (l00 note).
- [ ] Build-147 product test executed (hdeck `p1-milestone-product-test`) + 3sf streaming gate.
      Failures become P1 beads; they gate Gate 1's regression, not Opus starting work.
- [ ] Decision recorded: release cuts stay HUMAN (`scripts/release-ios.sh` is permission-gated for
      agents — deliberate). If the user wants agent-cut builds, add a Bash permission rule; not
      recommended.

## Gate 1 — data safety (arch-v2 P1, Lane A–C of the execution plan)
- [x] **arch-v3 delta review (2026-07-09)** — `glw` (`d54b6c3`): repair passes no longer outlive
      session teardown / adopt-swap, and factory reset quiesces them before wiping zones (it
      could otherwise resurrect the zone it just erased). `c57` (`02b1974`): pre-swap open-models
      users no longer persist an incompatible vendor+model pair.
- [x] **`ioj`** (`d7db0c8`) — permanent sync failures no longer self-clear on a clean tick; they
      persist until that record reaches the server (save OR delete). The `qrt` banner now fires
      for quota/auth/permission, restoring the ADR-3 "how would we know?" test.
- [x] r8q (`0bee2a7`) + c7r (`1197bdb`) + 6ce (`4a17515`) + dab (`24d0826`) engine core · 9zf
      (`94b4231`) · eky (`a907de6`) landed 2026-07-02, suites green (Kit 155 / CK 436 / app builds).
- [x] pr9 CKRecord defensive copies (`23efe83`, 2026-07-07) — store copy-in/copy-out + merger/rebase
      copy-before-mutate; CK 449 green.
- [ ] Fresh TestFlight build (148+): device regression — two-device edit storm converges (no lost
      fields), backup→recover round-trip, and the NEW cold-launch check: relaunch → full week
      visible immediately → a backup taken right after relaunch contains the FULL household.
      (Beaded: `6uj` regression bundle + `a97` sharing-gate remainder.)
- [x] qrt sync-status surface (`4aa4f06`, 2026-07-07) — derivation + center + onSyncError wiring +
      join progress + Settings row/banner. GATE-1 CODE COMPLETE: tree is cuttable as build 148
      (13j `ca0cb5f` empty-backup fix must be in the cut — see 6uj note).

## Gate 2 — product truth (no visible feature lies)
- [x] 7pr Smith tab/assistant entry points (`9984ec2`) · 962 Create-with-AI + Manage-sides
      (`9487101`) — landed 2026-07-02; tap-through proof rides bead `6uj`.
- [x] ebu grocery archive load via CloudKit (`44eaf0d`, 2026-07-07) — tombstone read via
      WeekRepository; restore path unchanged.
- [ ] Recipe memories: 990.4.1–.3 landed, OR the section is HIDDEN for launch (visible-but-broken
      is not shippable; hiding is a legitimate scope cut — record it if taken).
- [ ] Ingredients: 990.5.1–.3 landed, OR the link-picker/manage surfaces hidden (same rule).
- [ ] mm1 onboarding dead code deleted. Product-truth re-sweep (one Sonnet agent, the v2
      product-truth lens prompt) returns zero "dead backend" findings.

## Gate 3 — compliance & polish
- [ ] 5w8 privacy policy rewritten + live at its FINAL host (990.11 re-host precedes or lands
      together) + user updates the ASC privacy nutrition label to match BYO-key data flows.
- [ ] 9wr PUBLIC grant revoked in Production (user Dashboard op) + rejected-write verified.
- [ ] pb8 prod schema deploy covers every type shipped in the RC (incl. RecipeMemory* if Gate 2
      took the port path).
- [ ] 1sz accessibility pass on core flows · lwi share-accept warning · 0g5 MetricKit + 79y log
      export (the "how would we know" baseline).

## Gate 4 — submission package (vwq, user + Opus)
- [ ] Metadata: description, keywords, category, age rating; screenshots (6.9" + 6.5" minimum)
      from a data-rich sim household.
- [ ] App Review notes: BYO-key model explained + decision on a funded demo key; note that manual
      recipe entry works keyless (4.2 mitigation); demo household state on the reviewer path.
- [ ] Marketing version set (1.0.0), build cut via release-ios.sh (user), RC device checklist
      (one consolidated hdeck product test for the RC).
- [ ] Submit. On rejection: finding → bead → this runbook's gate re-opens; no ad-hoc fixes.

## Post-launch track (already beaded/recorded — do not pull forward)
Retirement chain 990.8–.12 · e0a store persistence (if not landed at Gate 1, land within the first
post-launch cycle — it upgrades offline durability) · credits-gateway bx1 · onboarding design exc ·
structural track (god-object/protocol seams/app-target tests — umbrella bead) · SP-B AFM at iOS 27 GA.
