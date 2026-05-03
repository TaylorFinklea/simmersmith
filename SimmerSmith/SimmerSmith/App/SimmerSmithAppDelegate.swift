import Foundation
import UIKit

/// UIApplicationDelegate adopted via `@UIApplicationDelegateAdaptor` on `SimmerSmithApp`.
///
/// Forwards APNs callbacks to `PushService.shared` so the app body
/// stays declarative. The environment is determined per-build:
/// `#if DEBUG` → sandbox; otherwise → production.
final class SimmerSmithAppDelegate: NSObject, UIApplicationDelegate {
    // Hold a reference to AppState so notification taps can switch tabs.
    // Injected in SimmerSmithApp via the adaptor property wrapper.
    var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // M22.1: register the BGAppRefreshTask handler before launch
        // returns. iOS rejects late registration with a runtime warning.
        Task { @MainActor in
            BackgroundSyncService.shared.registerLaunchHandler()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        guard let appState else { return }
        let environment: String
        #if DEBUG
        environment = "sandbox"
        #else
        environment = "production"
        #endif
        let bundleID = Bundle.main.bundleIdentifier ?? "app.simmersmith.ios"
        Task { @MainActor in
            PushService.shared.handleDeviceToken(
                deviceToken,
                environment: environment,
                bundleID: bundleID,
                apiClient: appState.apiClient
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Log only — a deny or simulator call never crashes.
        print("[AppDelegate] Remote notification registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let appState {
            Task { @MainActor in
                PushService.shared.handleRemoteNotification(userInfo: userInfo, appState: appState)
            }
        }
        completionHandler(.noData)
    }
}
