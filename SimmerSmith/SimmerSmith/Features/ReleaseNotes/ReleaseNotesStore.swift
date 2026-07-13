import Foundation

/// The impure edge of What's New: the running build number, and the per-device
/// record of which notes have already been shown.
///
/// Deliberately per-device (`UserDefaults`, not iCloud key-value store). If she
/// reads the notes on her phone and sees them again on an iPad, that costs one
/// tap; a sync dependency would give a no-network launch a brand-new way to
/// fail. The bead is explicit that no release-notes path may require a network,
/// an account, or an AI key.
struct ReleaseNotesStore {

    static let lastSeenBuildKey = "release_notes_last_seen_build"

    private let defaults: UserDefaults
    private let bundle: Bundle

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    /// CFBundleVersion of the running app. `nil` only if the Info.plist is
    /// malformed, in which case the caller shows nothing rather than guessing.
    var currentBuild: Int? {
        (bundle.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init)
    }

    /// Newest build whose notes have been shown *and dismissed* on this device.
    /// `nil` on a clean install — the gate treats that case specially.
    ///
    /// `object(forKey:)`, not `integer(forKey:)`: the latter reports a missing
    /// key as 0, which the gate would faithfully read as "last saw build 0" and
    /// answer by showing every release note ever written.
    var lastSeenBuild: Int? {
        defaults.object(forKey: Self.lastSeenBuildKey) as? Int
    }

    func markSeen(through build: Int) {
        defaults.set(build, forKey: Self.lastSeenBuildKey)
    }
}
