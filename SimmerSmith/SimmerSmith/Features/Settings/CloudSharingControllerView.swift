#if canImport(CloudKit)
import CloudKit
import UIKit

/// Presents the system `UICloudSharingController` for a prepared zone-wide CKShare so the owner
/// can add one partner via the native share sheet (Messages/Mail/etc.).
///
/// Presented DIRECTLY from the top view controller — NOT embedded as the root of a SwiftUI
/// `.sheet`. Embedding `UICloudSharingController` as a sheet's content view controller makes it
/// render then immediately dismiss itself (it expects to be presented modally, not embedded).
/// The share itself was created/fetched by `AppState.prepareOwnerShare` beforehand.
enum CloudSharingPresenter {

    @MainActor
    static func present(share: CKShare, container: CKContainer, onComplete: @escaping () -> Void = {}) {
        guard let top = topViewController() else { return }
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        let delegate = Delegate(onComplete: onComplete)
        controller.delegate = delegate
        // UICloudSharingController.delegate is weak — keep the delegate alive for the controller's
        // lifetime via an associated object so the save/stop callbacks still fire.
        objc_setAssociatedObject(controller, &Delegate.associatedKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        top.present(controller, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    final class Delegate: NSObject, UICloudSharingControllerDelegate {
        static var associatedKey: UInt8 = 0
        let onComplete: () -> Void
        init(onComplete: @escaping () -> Void) { self.onComplete = onComplete }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String ?? "SimmerSmith household"
        }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onComplete() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onComplete() }
    }
}
#endif
