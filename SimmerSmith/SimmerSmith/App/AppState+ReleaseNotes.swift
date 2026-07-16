import Foundation

// simmersmith-224 — What's New.
//
// Everything decidable lives in `ReleaseNotesGate` (pure, fully tested). This
// extension is only the wiring: read the device's state, ask the gate, park the
// answer where `RootView` can present it.
extension AppState {

    private var releaseNotesStore: ReleaseNotesStore { ReleaseNotesStore() }

    /// Decide whether this launch owes the user a What's New sheet.
    ///
    /// Called when the household reaches `.ready` — never before, so the sheet
    /// can't land on top of the iCloud-loading or sign-in screens. Safe to call
    /// repeatedly: it no-ops once a sheet is already pending, and once the notes
    /// have been marked seen the gate stops returning them.
    func evaluatePendingReleaseNotes() {
        guard pendingReleaseNotes == nil else { return }

        let store = releaseNotesStore
        guard let currentBuild = store.currentBuild else { return }

        let unseen = ReleaseNotesGate.unseen(
            catalog: ReleaseNotesCatalog.all,
            currentBuild: currentBuild,
            lastSeenBuild: store.lastSeenBuild
        )
        guard !unseen.isEmpty else { return }

        let previousNotes = ReleaseNotesGate.history(
            catalog: ReleaseNotesCatalog.all,
            through: currentBuild,
            excludingBuilds: Set(unseen.map(\.build))
        )
        pendingReleaseNotes = ReleaseNotesPresentation(
            notes: unseen,
            previousNotes: previousNotes
        )
    }

    /// Record that the notes have been seen. Called from the sheet's `onDismiss`
    /// — on dismissal, not on presentation. If the sheet is raised and the app
    /// dies before she reads it (or she is interrupted mid-cook), the notes come
    /// back next launch. Showing them twice is cheaper than losing them.
    func markReleaseNotesSeen() {
        pendingReleaseNotes = nil

        let store = releaseNotesStore
        guard let currentBuild = store.currentBuild else { return }
        store.markSeen(through: currentBuild)
    }
}
