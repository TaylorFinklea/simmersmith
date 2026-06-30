#if canImport(CloudKit)
import CloudKit
import UIKit

/// Receives CKShare acceptance for the SwiftUI lifecycle app. The deprecated
/// `application(_:userDidAcceptCloudKitShareWith:)` does NOT fire for `WindowGroup` apps,
/// so a scene delegate is wired via `UISceneConfiguration` (see `SimmerSmithAppDelegate`).
///
/// It does NOT create or assign a `window` — SwiftUI's `WindowGroup` owns the scene's
/// content. It only captures the share metadata (cold launch via `connectionOptions`,
/// warm tap via the callback) and routes it through `PendingShareInbox`.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the app was terminated when the user tapped the share link. The
    /// metadata rides in on the connection options; stash it for AppState to drain once
    /// it's constructed (SimmerSmithApp.task → ensureHouseholdSession).
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            print("[Sharing] scene(willConnectTo:) COLD launch with share metadata — depositing")
            Task { @MainActor in PendingShareInbox.shared.deposit(metadata) }
        }
    }

    /// Warm tap: the app was running. Deposit + process immediately so an already-booted
    /// owner session can swap to the participant household.
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        print("[Sharing] windowScene(userDidAcceptCloudKitShareWith:) WARM accept — depositing + processing")
        Task { @MainActor in
            PendingShareInbox.shared.deposit(cloudKitShareMetadata)
            let appState = (UIApplication.shared.delegate as? SimmerSmithAppDelegate)?.appState
            if appState == nil { print("[Sharing] WARM: appDelegate.appState is NIL — cannot process") }
            await appState?.processPendingShare()
        }
    }
}
#endif
