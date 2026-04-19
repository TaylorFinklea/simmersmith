import Foundation
import SimmerSmithKit

extension AppState {
    /// True when the backend's profile response or StoreKit's local
    /// entitlements say the user is Pro. The backend value wins when we
    /// have it (it's authoritative); StoreKit is the fallback while we're
    /// offline or the first API call hasn't completed yet.
    var isPro: Bool {
        if let profile {
            return profile.isPro
        }
        return subscriptionStore.isEntitled
    }

    /// True when the "Pro for everyone during beta" toggle is driving
    /// `isPro`, not a real StoreKit transaction. Used to render
    /// promotional copy in Settings instead of the subscription row.
    var isTrialPro: Bool {
        profile?.isTrial ?? false
    }

    /// The current monthly usage summary the server returned. Returns an
    /// empty list if the profile hasn't loaded yet.
    var usageSummaries: [UsageSummary] {
        profile?.usage ?? []
    }

    /// Helper for Settings / banner rendering: "used 1 of 1 this month".
    func usage(for action: String) -> UsageSummary? {
        usageSummaries.first { $0.action == action }
    }

    /// Present the paywall sheet. Safe to call repeatedly — the sheet
    /// re-renders with the latest reason.
    func presentPaywall(_ reason: PaywallReason) {
        pendingPaywall = reason
    }

    /// Dispatch a single transaction JWS to the backend to upsert the
    /// `Subscription` row, then refresh profile state so `isPro` and the
    /// usage summary update immediately.
    func verifySubscription(jws: String) async {
        do {
            _ = try await apiClient.verifySubscriptionTransaction(signedJWS: jws)
            await refreshAll()
        } catch {
            lastErrorMessage = "Pro sync failed: \(error.localizedDescription)"
        }
    }

    /// Map an `SimmerSmithAPIError.usageLimitReached` into a paywall
    /// presentation. Callers that catch API errors route through here so
    /// the behaviour stays consistent.
    func handleAPIError(_ error: Error) {
        if case SimmerSmithAPIError.usageLimitReached(let action, let limit, let used, _) = error {
            presentPaywall(.limitReached(action: action, used: used, limit: limit))
            return
        }
        lastErrorMessage = error.localizedDescription
    }
}
