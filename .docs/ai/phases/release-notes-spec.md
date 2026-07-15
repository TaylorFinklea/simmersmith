# What's New — versioned in-app release notes (simmersmith-224)

Status: build-152 core implemented; previous-release archive follow-up approved
2026-07-15 (`simmersmith-pto`).

## Goal

A non-technical TestFlight tester (the primary one is the owner's wife) should
learn what changed in each build she installs, without reading a changelog, a
commit log, or a TestFlight email.

## Approved follow-up — Previous Releases (`simmersmith-pto`)

### User outcome

Someone who installs several builds at once still sees every unseen release in
the automatic What's New sheet. Someone on a clean install, or anyone who wants
to reread older changes, can reach the useful release history directly from
that sheet instead of knowing to look elsewhere in Settings.

### Interaction

- Preserve the automatic launch presentation: all unseen, non-silent releases
  remain visible together, newest first.
- Add a secondary **Previous Releases** action when at least one older
  user-visible release exists. Do not show a dead-end action when history is
  empty.
- Push history inside the sheet's existing navigation stack. Back returns to
  the original notes; Close remains available; Got It keeps its existing
  dismissal behavior.
- Show older releases newest first with the existing release-note typography
  and New / Improved / Fixed groups.
- Settings → What's New opens the newest user-visible release available to the
  running build, with the same Previous Releases path, instead of dumping the
  full catalog into one long initial screen.

### Selection policy

The history selector is pure and accepts the running build plus the builds
already displayed. It returns catalog entries that are:

- at or below the running build;
- non-silent;
- not already present in the initial sheet; and
- sorted newest first.

This keeps pre-authored future notes private, hides signing/CI-only builds, and
avoids repeating releases when the automatic sheet already contains several
skipped builds. A silent current build in Settings falls back to the newest
earlier user-visible release. The clean-install rule remains unchanged: the
automatic sheet initially shows only the installed build; older notes require
an explicit tap.

### Boundaries

- Keep selection in `ReleaseNotesGate`; the SwiftUI views render supplied data
  and own only navigation state.
- Reuse the existing release rendering rather than creating a second visual
  interpretation of the catalog.
- Do not change `ReleaseNotesStore`, the per-device `lastSeenBuild` key, or the
  mark-on-dismiss rule. Browsing history never advances or rewinds seen state.
- No network, iCloud write, AI key, migration, or new persistence.
- This follow-up does not change cold-start performance. Shadow-mirror P2 owns
  cache-first launch.

### Test and acceptance gate

Implement test-first. A failing app-target test must establish the history
selector before production code is added. Pin that it excludes silent, future,
and already displayed builds; returns newest first; handles a silent current
build for Settings; and returns no action when no older visible release exists.
All existing unseen-release and mark-seen policies remain green.

Verify with the focused `SimmerSmithTests/ReleaseNotesGateTests` app-target
suite using the entitled ad-hoc-signed simulator host, followed by the generic
iOS build. The final review must also inspect the sheet for accessible button,
Back, and Close labels.

## The spec deviation that makes it work

The bead specified a catalog keyed by `MARKETING_VERSION`. `MARKETING_VERSION`
has been `1.0.0` for 150+ TestFlight builds and will stay there until launch,
so a marketing-version key would raise the sheet exactly once and then never
again — the opposite of the goal. Entries are keyed on `CURRENT_PROJECT_VERSION`
(the build number), which is the only identifier that moves on every release and
therefore gives both the gate key and a free total ordering. ADR in
`decisions.md` (2026-07-13).

## Shape

- `Features/ReleaseNotes/ReleaseNote.swift` — model. `build` (key), `version`,
  `date`, `headline`, and `new` / `improved` / `fixed`. `isSilent` = all three
  empty.
- `Features/ReleaseNotes/ReleaseNotesCatalog.swift` — **the file you edit when
  cutting a release.** Hand-authored Swift literal: compile-checked, no decode
  path, no resource-bundling question.
- `Features/ReleaseNotes/ReleaseNotesGate.swift` — pure. `unseen(catalog:
  currentBuild:lastSeenBuild:)`. No UserDefaults, no Bundle, no clock.
- `Features/ReleaseNotes/ReleaseNotesStore.swift` — the impure edge.
  `UserDefaults` (per-device, not iCloud — the bead forbids a network/account
  dependency) + `Bundle.main` CFBundleVersion.
- `Features/ReleaseNotes/ReleaseNotesSheet.swift` — renders whatever notes it is
  handed. Does not decide what to show; does not record that it was shown.
- `App/AppState+ReleaseNotes.swift` — wiring only.
  `pendingReleaseNotes` is stored on `AppState` beside `pendingPaywall`.
- `App/RootView.swift` — second `.sheet(item:)`, fired from an `onChange` of
  `householdLaunchPhase` reaching `.ready`.
- `Features/Settings/SettingsView.swift` — an `about` section: the app's version
  (shown nowhere else in the app) and a What's New row. The build-152 version
  opens the full catalog; `simmersmith-pto` replaces that long initial screen
  with the newest visible release plus the explicit history path above.
- `scripts/release-ios.sh` — preflight before archive.

## Policies the gate encodes (each pinned by a test)

| Policy | Why |
|---|---|
| Show entries with `build > lastSeenBuild` | Skipping 151→155 shows all four, not just the last |
| Never show `build > currentBuild` | Notes are written *before* the build ships (the preflight demands it) |
| Never show a silent entry | A signing-fix rebuild must not interrupt her cooking |
| Clean install → only the installed build's entry | Not the entire release history |
| Downgrade (`lastSeen > current`) → nothing | TestFlight can move a tester backwards |
| Mark seen on **dismiss**, not on present | A sheet she never read comes back; showing twice beats losing it |

## Two independent guards against a note-less release

1. `scripts/release-ios.sh` greps the catalog for `build: <N>,` before the
   archive and exits non-zero if absent. Fast, but a grep.
2. `ReleaseNotesCatalogTests.theShippedCatalogHasAnEntryForTheBuildItIsCompiledInto`
   asserts the catalog contains an entry for `Bundle.main`'s real
   CFBundleVersion. Cannot be fooled by a reformat.

"Nothing user-visible this build" is a valid, *explicit* answer: an entry with
all three lists empty satisfies both guards and shows no sheet.

## Verification performed

- 13 new tests (gate ×8, store ×3, catalog ×2). Full app suite 68/68 green
  (baseline was 55).
- The store's fresh-device test was mutation-checked against the
  `integer(forKey:)` implementation and correctly failed — that bug would have
  dumped the entire catalog on a new install.
- Sheet rendered in the simulator and screenshotted. Note: the sim's household
  never reaches `.ready` (its iCloud account needs re-auth), so the sheet had to
  be raised via a temporary patch that was reverted before commit. **The launch
  path itself is unverified on a real device** — see the open item below.

## Open

- Device-verify the once-per-update trigger on the next TestFlight build: install
  152 over 151 and confirm the sheet appears once and does not return on a later
  foreground. Tracked as a bead.
- When the onboarding bead (simmersmith-exc's child) lands, a brand-new user
  would get onboarding *and* What's New. Onboarding should call
  `markReleaseNotesSeen()` on completion to suppress the second sheet.
