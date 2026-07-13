import Foundation

/// Decides which release notes a device should see.
///
/// Pure by design — no `UserDefaults`, no `Bundle`, no clock. Every policy it
/// encodes (what counts as unseen, what a clean install sees, what happens on
/// a TestFlight downgrade) is therefore pinned by `ReleaseNotesGateTests`
/// rather than being implicit in view code.
enum ReleaseNotesGate {

    /// Release notes to show now, newest release first.
    ///
    /// - Parameters:
    ///   - catalog: every release note the app ships with.
    ///   - currentBuild: CFBundleVersion of the running app.
    ///   - lastSeenBuild: the newest build whose notes have been shown and
    ///     dismissed on this device, or `nil` on a clean install.
    static func unseen(
        catalog: [ReleaseNote],
        currentBuild: Int,
        lastSeenBuild: Int?
    ) -> [ReleaseNote] {
        // A clean install has seen nothing, but must not be handed the entire
        // release history — treat it as though it had just seen the build
        // before the one it installed, so it sees only that install's notes.
        let floor = lastSeenBuild ?? (currentBuild - 1)

        return catalog
            .filter { note in
                note.build > floor          // unseen…
                    && note.build <= currentBuild  // …but not from the future
                    && !note.isSilent              // …and worth saying out loud
            }
            .sorted { $0.build > $1.build }
    }
}
