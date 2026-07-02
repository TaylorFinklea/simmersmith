# Launch runbook — the gates between here and the App Store (Fable, 2026-07-02)

The definition of "ready for prod." Opus maintains this: check gates off as beads close, never
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
- [ ] r8q + c7r + 6ce + dab (engine core, sequential) · 9zf · eky · pr9 landed, suites green.
- [ ] Fresh TestFlight build (148+): device regression — two-device edit storm converges (no lost
      fields), backup→recover round-trip, and the NEW cold-launch check: relaunch → full week
      visible immediately → a backup taken right after relaunch contains the FULL household.
- [ ] qrt sync-status surface (a failing save is user-visible before we ship to strangers).

## Gate 2 — product truth (no visible feature lies)
- [ ] 7pr Smith tab/assistant entry points · 962 Create-with-AI + Manage-sides · ebu grocery archive.
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
