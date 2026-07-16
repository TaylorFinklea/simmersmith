import Foundation
import Testing

@testable import SimmerSmith

/// The gate is the entire behavioral contract of What's New: which release
/// notes a given device should see, and exactly once. It is deliberately pure
/// — no UserDefaults, no Bundle — so every policy decision below is pinned by
/// a test rather than buried in view code.
struct ReleaseNotesGateTests {

    // MARK: - Fixtures

    private func note(
        build: Int,
        new: [String] = [],
        improved: [String] = [],
        fixed: [String] = []
    ) -> ReleaseNote {
        ReleaseNote(
            build: build,
            version: "1.0.0",
            date: "July 13, 2026",
            headline: "Build \(build)",
            new: new,
            improved: improved,
            fixed: fixed
        )
    }

    private var catalog: [ReleaseNote] {
        [
            note(build: 150, fixed: ["An older fix"]),
            note(build: 151, new: ["An older feature"]),
            note(build: 152, new: ["The newest feature"], fixed: ["The newest fix"]),
        ]
    }

    // MARK: - Core gate

    @Test
    func showsOnlyNotesNewerThanTheLastOneSeen() {
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 152, lastSeenBuild: 150)

        #expect(unseen.map(\.build) == [152, 151])
    }

    @Test
    func returnsTheNewestReleaseFirst() {
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 152, lastSeenBuild: 149)

        #expect(unseen.map(\.build) == [152, 151, 150])
    }

    @Test
    func showsNothingWhenTheCurrentBuildHasAlreadyBeenSeen() {
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 152, lastSeenBuild: 152)

        #expect(unseen.isEmpty)
    }

    // MARK: - Clean install

    @Test
    func aCleanInstallSeesOnlyTheBuildItActuallyInstalled() {
        // Nothing stored yet. A new install must not be handed the entire
        // release history — only the notes for the build now on the phone.
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 152, lastSeenBuild: nil)

        #expect(unseen.map(\.build) == [152])
    }

    // MARK: - Defensive edges

    @Test
    func ignoresNotesForBuildsNewerThanTheOneRunning() {
        // Notes are written before the build ships (release-ios.sh refuses to
        // archive without them), so the catalog legitimately runs ahead of the
        // installed build. Those entries must stay invisible until they land.
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 151, lastSeenBuild: 150)

        #expect(unseen.map(\.build) == [151])
    }

    @Test
    func aDowngradeShowsNothingRatherThanMisbehaving() {
        // TestFlight can move a tester backwards onto an older build.
        let unseen = ReleaseNotesGate.unseen(catalog: catalog, currentBuild: 150, lastSeenBuild: 152)

        #expect(unseen.isEmpty)
    }

    @Test
    func skipsBuildsWithNoUserVisibleChanges() {
        // An entry with no items is how a release says "nothing worth telling
        // you about". It satisfies the release preflight but must never raise
        // a sheet — otherwise a signing-fix rebuild interrupts her cooking.
        let silent = [note(build: 153)]

        let unseen = ReleaseNotesGate.unseen(catalog: silent, currentBuild: 153, lastSeenBuild: 152)

        #expect(unseen.isEmpty)
    }

    @Test
    func aSilentBuildDoesNotSuppressAnEarlierUnseenRelease() {
        let mixed = [
            note(build: 152, new: ["A real change"]),
            note(build: 153),
        ]

        let unseen = ReleaseNotesGate.unseen(catalog: mixed, currentBuild: 153, lastSeenBuild: 151)

        #expect(unseen.map(\.build) == [152])
    }

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
}

/// The store is the impure edge — the running build number and the per-device
/// record of what has already been shown.
struct ReleaseNotesStoreTests {

    private func emptyStore() -> (ReleaseNotesStore, UserDefaults) {
        // A private suite per test: real UserDefaults behavior, no shared state.
        let suite = "release-notes-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (ReleaseNotesStore(defaults: defaults), defaults)
    }

    @Test
    func aFreshDeviceHasSeenNothingRatherThanHavingSeenBuildZero() {
        // The distinction that matters: `UserDefaults.integer(forKey:)` returns
        // 0 for a missing key, which the gate would read as "last saw build 0"
        // and answer by dumping the entire release history on a new install.
        // Absent must stay absent.
        let (store, _) = emptyStore()

        #expect(store.lastSeenBuild == nil)
    }

    @Test
    func markingSeenPersistsTheBuild() {
        let (store, _) = emptyStore()

        store.markSeen(through: 152)

        #expect(store.lastSeenBuild == 152)
    }

    @Test
    func theRunningBuildIsReadFromTheBundle() throws {
        let store = ReleaseNotesStore()

        let build = try #require(store.currentBuild, "CFBundleVersion unreadable")
        #expect(build > 0)
    }
}

/// Guards the invariant the whole feature rests on: a build we ship must have
/// something to say for itself. `release-ios.sh` enforces this before an
/// archive; this enforces it on every test run, and cannot be fooled by a
/// reformat of the catalog the way a grep can.
struct ReleaseNotesCatalogTests {

    @Test
    func theShippedCatalogHasAnEntryForTheBuildItIsCompiledInto() throws {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let currentBuild = try #require(
            raw.flatMap(Int.init),
            "CFBundleVersion is missing or non-numeric"
        )

        #expect(
            ReleaseNotesCatalog.all.contains { $0.build == currentBuild },
            "No release-note entry for build \(currentBuild) — add one to ReleaseNotesCatalog.all"
        )
    }

    @Test
    func catalogBuildNumbersAreUnique() {
        let builds = ReleaseNotesCatalog.all.map(\.build)

        #expect(builds.count == Set(builds).count)
    }
}
