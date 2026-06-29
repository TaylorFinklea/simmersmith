#if canImport(CloudKit)
import CloudKit

/// A one-shot hand-off for CKShare acceptance metadata between the scene delegate (which
/// receives it, possibly at cold launch before AppState exists) and AppState (which boots
/// the participant session). `take()` clears it so the cold-launch drain and a warm-tap
/// handler can't both process the same accept.
@MainActor
final class PendingShareInbox {
    static let shared = PendingShareInbox()
    private init() {}

    private var metadata: CKShare.Metadata?

    func deposit(_ metadata: CKShare.Metadata) { self.metadata = metadata }

    /// Returns the pending metadata once, then clears it.
    func take() -> CKShare.Metadata? {
        defer { metadata = nil }
        return metadata
    }

    var hasPending: Bool { metadata != nil }
}
#endif
