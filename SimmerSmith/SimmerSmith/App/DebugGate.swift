import Foundation

/// Controls whether developer-only surfaces (the SP-A CloudKit-checks panel) are reachable.
///
/// True in DEBUG (simulator / Xcode device builds) and in TestFlight builds (their App Store
/// receipt is a `sandboxReceipt`); false in App Store builds (a production `receipt`). So the
/// CloudKit checks reach our own beta testing on TestFlight but never ship to App Store users —
/// even though `CloudKitDebugView` itself now compiles into the Release binary.
enum DebugGate {
    static var showsCloudKitChecks: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }
}
