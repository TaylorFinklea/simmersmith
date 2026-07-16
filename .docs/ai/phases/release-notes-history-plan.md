# Previous Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-sheet Previous Releases archive that exposes older user-visible release notes without changing skipped-build delivery or seen-state semantics.

**Architecture:** Keep release selection pure in `ReleaseNotesGate`. Extend the existing value-type presentation to carry both the initially displayed notes and its prefiltered history, then let `ReleaseNotesSheet` own only local push navigation. Settings constructs the same presentation from the running build and uses item-driven sheet state.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, Xcode 26, existing SimmerSmith design-system primitives.

## Global Constraints

- History contains only non-silent entries at or below the running build.
- History excludes every build already displayed in the initial sheet and stays newest first.
- Automatic launch behavior remains all unseen non-silent builds; clean install remains current build only.
- Settings starts on the newest user-visible release and puts all older visible entries behind Previous Releases.
- `ReleaseNotesStore`, `lastSeenBuild`, and mark-on-dismiss behavior do not change.
- No network, iCloud write, AI key, persistence, migration, dependency, or cold-start change.
- Use the existing release-note visual language and explicit accessible labels for Previous Releases, Back, and Close.
- The owner's standing authorization includes push and TestFlight release operations for this work.

---

### Task 1: Implement the previous-release presentation end to end

**Files:**
- Modify: `SimmerSmith/SimmerSmithTests/ReleaseNotesTests.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesGate.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNote.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+ReleaseNotes.swift`
- Modify: `SimmerSmith/SimmerSmith/App/RootView.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesSheet.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `ReleaseNote.isSilent`, `ReleaseNotesGate.unseen`, `ReleaseNotesStore.currentBuild`, `ReleaseNotesCatalog.all`, `ReleaseNotesPresentation`, and the existing release-note sheet/presentation call sites.
- Produces: `ReleaseNotesGate.history(catalog:through:excludingBuilds:) -> [ReleaseNote]`; `ReleaseNotesPresentation.previousNotes`; one item-driven Settings presentation; one in-sheet Previous Releases destination.

- [ ] **Step 1: Write the failing pure-policy tests**

Add these tests inside `ReleaseNotesGateTests`, after the existing defensive-edge tests:

```swift
    // MARK: - Previous releases

    @Test
    func historyExcludesSilentFutureAndAlreadyDisplayedBuilds() {
        let mixed = [
            note(build: 149, fixed: ["Oldest visible fix"]),
            note(build: 150, new: ["Older visible feature"]),
            note(build: 151),
            note(build: 152, improved: ["Already on screen"]),
            note(build: 153, new: ["Authored for a future build"]),
        ]

        let history = ReleaseNotesGate.history(
            catalog: mixed,
            through: 152,
            excludingBuilds: [152]
        )

        #expect(history.map(\.build) == [150, 149])
    }

    @Test
    func historyExcludesEveryReleaseAlreadyShownInASkippedBuildBatch() {
        let history = ReleaseNotesGate.history(
            catalog: catalog,
            through: 152,
            excludingBuilds: [152, 151]
        )

        #expect(history.map(\.build) == [150])
    }

    @Test
    func aSilentCurrentBuildFallsBackToTheNewestVisibleReleaseForSettings() {
        let mixed = [
            note(build: 150, fixed: ["Older fix"]),
            note(build: 151, new: ["Newest visible feature"]),
            note(build: 152),
        ]

        let visible = ReleaseNotesGate.history(catalog: mixed, through: 152)

        #expect(visible.map(\.build) == [151, 150])
        #expect(visible.first?.build == 151)
    }

    @Test
    func historyIsEmptyWhenNoOlderVisibleReleaseExists() {
        let history = ReleaseNotesGate.history(
            catalog: [note(build: 152, new: ["Only visible release"])],
            through: 152,
            excludingBuilds: [152]
        )

        #expect(history.isEmpty)
    }

    @Test
    func presentationKeepsInitialAndPreviousNotesSeparate() {
        let current = note(build: 152, new: ["Current feature"])
        let previous = note(build: 151, fixed: ["Previous fix"])

        let presentation = ReleaseNotesPresentation(
            notes: [current],
            previousNotes: [previous]
        )

        #expect(presentation.notes.map(\.build) == [152])
        #expect(presentation.previousNotes.map(\.build) == [151])
    }
```

- [ ] **Step 2: Run the focused tests and prove RED**

Run:

```bash
bash scripts/dev-sim.sh
xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination name=SimmerSmithSim \
  -only-testing:SimmerSmithTests/ReleaseNotesGateTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
```

Expected: build failure because `ReleaseNotesGate` has no member `history` and
`ReleaseNotesPresentation` has no `previousNotes` memberwise argument. A
simulator/bootstrap or signing failure is not the required RED; fix the test
host and rerun until the missing policy/model APIs are the failure.

- [ ] **Step 3: Implement the minimal pure selector and presentation value**

Add this method to `ReleaseNotesGate` after `unseen`:

```swift
    /// User-visible release history through the running build, newest first.
    /// `excludingBuilds` prevents an automatic skipped-build batch from being
    /// repeated when the user explicitly opens Previous Releases.
    static func history(
        catalog: [ReleaseNote],
        through currentBuild: Int,
        excludingBuilds: Set<Int> = []
    ) -> [ReleaseNote] {
        catalog
            .filter { note in
                note.build <= currentBuild
                    && !note.isSilent
                    && !excludingBuilds.contains(note.build)
            }
            .sorted { $0.build > $1.build }
    }
```

Extend `ReleaseNotesPresentation` in `ReleaseNote.swift` so the second RED has
the smallest implementation that can pass:

```swift
struct ReleaseNotesPresentation: Identifiable, Equatable {
    let notes: [ReleaseNote]
    let previousNotes: [ReleaseNote]

    /// The newest release in the batch — stable for the life of the sheet.
    var id: Int { notes.first?.build ?? 0 }
}
```

- [ ] **Step 4: Run the focused tests and prove GREEN**

Run the exact `xcodebuild test` command from Step 2.

Expected: all `ReleaseNotesGateTests` pass, including the four new history
tests, the presentation-value test, and every existing unseen-release policy
test.

- [ ] **Step 5: Carry prefiltered history through the launch presentation**

In `AppState+ReleaseNotes.swift`, preserve `unseen` and construct the launch presentation with prefiltered history:

```swift
        let previousNotes = ReleaseNotesGate.history(
            catalog: ReleaseNotesCatalog.all,
            through: currentBuild,
            excludingBuilds: Set(unseen.map(\.build))
        )
        pendingReleaseNotes = ReleaseNotesPresentation(
            notes: unseen,
            previousNotes: previousNotes
        )
```

In `RootView.swift`, pass the item directly:

```swift
            ReleaseNotesSheet(presentation: presentation)
```

- [ ] **Step 6: Add the in-sheet archive using the existing renderer**

Refactor `ReleaseNotesSheet.swift` without changing its visual tokens:

```swift
import SwiftUI

struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: ReleaseNotesPresentation

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.paper.ignoresSafeArea()
                PaperGrain().ignoresSafeArea()

                ScrollView {
                    VStack(spacing: SMSpacing.xl) {
                        FuMark(size: 48, color: SMColor.ink, ember: SMColor.ember)
                            .padding(.top, SMSpacing.sm)

                        ReleaseNotesEntries(notes: presentation.notes)

                        if !presentation.previousNotes.isEmpty {
                            NavigationLink {
                                PreviousReleasesView(
                                    notes: presentation.previousNotes,
                                    close: { dismiss() }
                                )
                            } label: {
                                HStack(spacing: SMSpacing.sm) {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text("Previous Releases")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.ember)
                                .padding(.horizontal, SMSpacing.lg)
                                .padding(.vertical, SMSpacing.md)
                                .background(
                                    SMColor.paperAlt,
                                    in: RoundedRectangle(
                                        cornerRadius: SMRadius.md,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: SMRadius.md,
                                        style: .continuous
                                    )
                                    .stroke(SMColor.ember.opacity(0.35), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows earlier release notes")
                        }

                        Button {
                            dismiss()
                        } label: {
                            FuEmberCTA(label: "Got it")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, SMSpacing.sm)
                    }
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.xl)
                }
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.large])
    }
}

private struct PreviousReleasesView: View {
    let notes: [ReleaseNote]
    let close: () -> Void

    var body: some View {
        ZStack {
            SMColor.paper.ignoresSafeArea()
            PaperGrain().ignoresSafeArea()

            ScrollView {
                ReleaseNotesEntries(notes: notes)
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.xl)
            }
        }
        .navigationTitle("Previous Releases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close", action: close)
                    .foregroundStyle(SMColor.ember)
            }
        }
        .smithToolbar()
    }
}

private struct ReleaseNotesEntries: View {
    let notes: [ReleaseNote]

    var body: some View {
        VStack(spacing: SMSpacing.xl) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                if index > 0 {
                    DashedRule()
                        .padding(.vertical, SMSpacing.xs)
                }
                release(note)
            }
        }
    }

    private func release(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.lg) {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(note.headline)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                FuEyebrow(text: note.date, ember: true)

                Text("Version \(note.version) (\(note.build))")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            group("New", systemImage: "sparkles", items: note.new)
            group("Improved", systemImage: "hammer", items: note.improved)
            group("Fixed", systemImage: "wrench.and.screwdriver", items: note.fixed)
        }
    }

    @ViewBuilder
    private func group(_ title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                HStack(spacing: SMSpacing.xs) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(SMColor.ember)
                    FuEyebrow(text: title, ember: true)
                }

                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: SMSpacing.sm) {
                        Text("—")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.ember.opacity(0.65))
                        Text(item)
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

The `NavigationLink` text is the accessible button label, the stack supplies Back, and the destination's trailing Close preserves both actions simultaneously.

- [ ] **Step 7: Make Settings item-driven and start at the newest visible release**

Replace `showingReleaseNotes` with:

```swift
    /// Settings opens the newest user-visible release and keeps older entries
    /// behind the same Previous Releases navigation used at launch.
    @State private var releaseNotesPresentation: ReleaseNotesPresentation?
```

Add this helper next to `appVersionDisplay`:

```swift
    private func makeReleaseNotesPresentation() -> ReleaseNotesPresentation? {
        let store = ReleaseNotesStore()
        guard let currentBuild = store.currentBuild else { return nil }

        let visibleNotes = ReleaseNotesGate.history(
            catalog: ReleaseNotesCatalog.all,
            through: currentBuild
        )
        guard let newest = visibleNotes.first else { return nil }

        return ReleaseNotesPresentation(
            notes: [newest],
            previousNotes: Array(visibleNotes.dropFirst())
        )
    }
```

Change the What's New button action to:

```swift
                    releaseNotesPresentation = makeReleaseNotesPresentation()
```

Replace its sheet modifier with:

```swift
        .sheet(item: $releaseNotesPresentation) { presentation in
            ReleaseNotesSheet(presentation: presentation)
        }
```

- [ ] **Step 8: Run the complete verification gate**

Run:

```bash
bash scripts/dev-sim.sh
xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination name=SimmerSmithSim \
  -only-testing:SimmerSmithTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: the full app-target suite passes, the generic iOS build prints `** BUILD SUCCEEDED **`, and `git diff --check` exits 0.

- [ ] **Step 9: Self-review and commit**

Review the final diff for these invariants before closing:

- Existing `ReleaseNotesGate.unseen` is byte-for-byte behaviorally unchanged.
- No silent or future release can enter Previous Releases.
- Every initially displayed build is excluded from history.
- Settings uses `.sheet(item:)`; browsing history never writes `lastSeenBuild`.
- Previous Releases, Back, and Close have explicit/native accessible labels.

After the self-review passes, commit the implementation. The controller owns
bead closure and tracked handoff updates after the external task review:

```bash
git add SimmerSmith/SimmerSmithTests/ReleaseNotesTests.swift \
  SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesGate.swift \
  SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNote.swift \
  SimmerSmith/SimmerSmith/App/AppState+ReleaseNotes.swift \
  SimmerSmith/SimmerSmith/App/RootView.swift \
  SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesSheet.swift \
  SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift
git commit -m "feat(release-notes): show previous releases"
```

---

### Task 2: Cut and validate TestFlight build 159 (controller-owned)

**Ownership:** The root controller executes this task after Task 1's task-level
and whole-change reviews pass. Do not dispatch credentials, push, or App Store
Connect operations to the implementation worker.

**Files:**
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift`
- Modify: `SimmerSmith/project.yml`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`
- Modify after external verification: `.docs/ai/current-state.md`
- Modify after external verification: `.docs/ai/phases/release-notes-spec.md`

**Interfaces:**
- Consumes: the reviewed Task-1 feature commit, `scripts/release-ios.sh`, App Store Connect API-key flow, GitHub Actions.
- Produces: build 159 with a catalog entry, a green CI run, terminal App Store Connect `VALID`, internal Finklea Dev assignment, and a durable release handoff.

- [ ] **Step 1: Add release notes and bump the build**

After the feature commit, add the build-159 catalog entry at the top of
`ReleaseNotesCatalog.all`:

```swift
        ReleaseNote(
            build: 159,
            version: "1.0.0",
            date: "July 15, 2026",
            headline: "Catch up anytime",
            new: [
                "What's New now has a Previous Releases button, so you can catch up on changes from builds you skipped.",
            ],
            improved: [],
            fixed: []
        ),
```

Set `CURRENT_PROJECT_VERSION: 159` in `SimmerSmith/project.yml`, then run:

```bash
xcodegen generate --spec SimmerSmith/project.yml
bash scripts/dev-sim.sh
xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination name=SimmerSmithSim \
  -only-testing:SimmerSmithTests/ReleaseNotesCatalogTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=-
xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
```

Expected: both catalog tests pass and the build prints `** BUILD SUCCEEDED **`.
Commit those mechanical release changes separately:

```bash
git add SimmerSmith/project.yml \
  SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj \
  SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift
git commit -m "chore(release): bump to build 159 [skip ci]"
```

- [ ] **Step 2: Push, wait for CI, upload, and verify external state**

Push `main`, wait for the GitHub Actions run triggered by the feature commit to
finish green, run `./scripts/release-ios.sh`, and wait for the script's terminal
`VALID` result. Confirm App Store Connect assigned build 159 to the internal
Finklea Dev group. Update `current-state.md` with the feature commit, CI run,
and TestFlight status; update `release-notes-spec.md` to mark the archive shipped;
close `simmersmith-pto`; keep e0a P1e open because this feature does not supply
its online/offline device evidence. Use these commands for the push and CI gate:

```bash
git push origin main
feature_sha="$(git log --format=%H --grep='^feat(release-notes): show previous releases$' -1)"
run_id="$(gh run list --commit "$feature_sha" --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$run_id" --exit-status
./scripts/release-ios.sh
```

Select the run whose head SHA is the Task-1 feature commit; do not substitute
the `[skip ci]` build-bump commit. The release script supplies the terminal App
Store Connect processing verdict. Commit and push the final handoff update:

```bash
git add .docs/ai/current-state.md .docs/ai/phases/release-notes-spec.md
git commit -m "docs(ai): record build 159 release [skip ci]"
git push origin main
```
