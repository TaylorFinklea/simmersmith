# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. Keep lean.
> Backlog/ready-queue → beads (`bd ready`). History → git log + decisions.md + phases/*.

## 2026-07-03 — HANDOFF: Opus/Fable unavailable for weeks; Sonnet 5 = acting Lead

- Branch: `main`, local-only (~38 commits ahead; push = bead `tjc`, user). Tree clean except the
  standing uncommitted `project.pbxproj` — leave unstaged unless project.yml changed.
- WHO: Sonnet 5 acting Lead — bd memories `delegation-method` + `lead-succession` (surface via
  `bd prime`). Per-bead loop: `bd ready` → impl (delegate per delegation-method; impl agents get
  the no-git/bd-authority line) → INDEPENDENT adversarial verify → personal backstop
  (`swift test --package-path SimmerSmithKit` + `--package-path SimmerSmithCloudKit` + app
  xcodebuild, fresh -derivedDataPath after xcodegen) → commit → `bd close` → docs.
- WHERE: destination = `phases/launch-runbook.md` (Gates 0–4, epic `0lm`; checkboxes current
  2026-07-03). Lane map + non-negotiables = `phases/arch-v2-execution-plan.md` (STATUS block).
- DONE 2026-07-02 — arch-v2 P1 wave, 8 beads: `7pr 962 r8q c7r 6ce dab 9zf eky` (hashes in the
  execution-plan STATUS block). Suites: Kit 155 / CK 436 / app builds.
- NEXT code (order): `pr9` (Lane C last item — bead carries a post-eky grounding note) → Gate 2
  `ebu` `mm1` + recipe-memories `990.4.x`/ingredients `990.5.x` (or HIDE — record the cut) →
  Gate 3 agent halves `5w8` `9wr`.
- BLOCKED ON USER: push main (`tjc`) · cut TestFlight 148+ (`scripts/release-ios.sh`, human-only)
  · then device gates: `6uj` Gate-1 regression · `a97` sharing · `nli` voice · `3hn` backup ·
  `3sf` streaming · build-147 product test (hdeck `p1-milestone-product-test`) · `9wr` Dashboard
  deploy · `pb8` prod schema.
- Open questions: none. Gate-2 hide-vs-fix cuts → decisions.md when taken.

## Plan

(empty — pull the next bead from `bd ready`; expand a multi-phase bead into checkboxes here, one
item per iteration; every unchecked item needs a `Verify:` COMMAND or headless ralph refuses)

## Archive pointers (history lives in git/phases/decisions — do not re-grow prose here)

- Arch reviews + queue rebuild: `phases/arch-review-2026-07-01-report.md` +
  `phases/arch-review-v2-2026-07-02-report.md` + decisions.md 2026-07-01/02 ADRs.
- 3sf token streaming: code COMPLETE incl. the OpenRouter pivot (`c7fa6a8`); device gate only.
  Spec `phases/oss-assistant-streaming-spec.md`; state in bead `3sf`.
- Shipped-awaiting-device-gate: Backup/Restore b145 (`3hn`, spec `phases/backup-restore-spec.md`)
  · sharing v1 b142–144 (`a97`, spec `phases/household-sharing-spec.md`) · voice b141 (`nli`,
  spec `phases/voice-week-planning-spec.md`).
- Superseded: direct GLM/Kimi/MiniMax vendor UI (OpenRouter pivot — dormant code stays, see
  execution-plan "What NOT to do") · all Fly-era open items (SP-D epic `990`).
