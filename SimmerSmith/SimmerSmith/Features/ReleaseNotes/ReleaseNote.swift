import Foundation

/// One shipped release, described the way the person using the app would
/// describe it — not the way a commit log does.
///
/// Keyed on `build` (CURRENT_PROJECT_VERSION) rather than MARKETING_VERSION.
/// The marketing version has been 1.0.0 for 150+ TestFlight builds, so a
/// marketing-version key would raise the What's New sheet exactly once and
/// then stay silent through every future TestFlight release. The build number
/// is the only identifier that actually moves each time we ship. See
/// `.docs/ai/decisions.md`.
struct ReleaseNote: Identifiable, Equatable, Sendable {
    /// CURRENT_PROJECT_VERSION for this release. The gate key, and the total
    /// order the gate relies on.
    let build: Int

    /// MARKETING_VERSION — shown next to the build, never used for gating.
    let version: String

    /// Display-only, hand-authored (e.g. "July 13, 2026").
    let date: String

    /// One friendly line summing the release up.
    let headline: String

    let new: [String]
    let improved: [String]
    let fixed: [String]

    var id: Int { build }

    /// A release with nothing worth telling the user about — a signing-fix
    /// rebuild, a CI-only change. The entry still exists so the release
    /// preflight can find one, but it never raises a sheet.
    var isSilent: Bool {
        new.isEmpty && improved.isEmpty && fixed.isEmpty
    }
}

/// Identity wrapper so `RootView` can drive the sheet with `.sheet(item:)`,
/// exactly as it already does for `pendingPaywall`.
struct ReleaseNotesPresentation: Identifiable, Equatable {
    let notes: [ReleaseNote]
    let previousNotes: [ReleaseNote]

    /// The newest release in the batch — stable for the life of the sheet.
    var id: Int { notes.first?.build ?? 0 }
}
