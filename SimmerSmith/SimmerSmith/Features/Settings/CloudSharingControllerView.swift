#if canImport(CloudKit)
import CloudKit
import SwiftUI
import UIKit

/// Presents the system `UICloudSharingController` for a prepared zone-wide CKShare so the
/// owner can add exactly one partner via the native share sheet (Messages/Mail/etc.).
/// Named-participant model: read-write, private. The share itself was created/fetched by
/// `AppState.prepareOwnerShare` before this is presented.
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    var onComplete: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onComplete: () -> Void
        init(onComplete: @escaping () -> Void) { self.onComplete = onComplete }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String ?? "SimmerSmith household"
        }

        func cloudSharingController(
            _ csc: UICloudSharingController, failedToSaveShareWithError error: Error
        ) {
            // The controller surfaces the error to the user; nothing to persist here.
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { onComplete() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { onComplete() }
    }
}
#endif
