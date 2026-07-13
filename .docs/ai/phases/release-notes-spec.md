# What's New — versioned in-app release notes (simmersmith-224)

Status: implemented, build 152.

## Goal

A non-technical TestFlight tester (the primary one is the owner's wife) should
learn what changed in each build she installs, without reading a changelog, a
commit log, or a TestFlight email.

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
  (shown nowhere else in the app) and a What's New row opening the full catalog.
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
