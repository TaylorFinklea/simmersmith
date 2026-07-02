import Foundation
import SimmerSmithKit

extension AppState {
    /// True when local StoreKit 2 entitlements say the user has an active
    /// Pro subscription. StoreKit is now the ONLY source of truth — the
    /// Fly-backed "server wins" behavior (and the Fly-only "Pro for
    /// everyone during beta" trial concept it carried) has been retired
    /// now that the paywall is local-only (see `MonetizationFlags`).
    var isPro: Bool {
        subscriptionStore.isEntitled
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
    /// re-renders with the latest reason. No-ops while the paywall is
    /// darkened (`MonetizationFlags.paywallEnabled == false`) so every
    /// upgrade entry point — the Settings upgrade button, usage-limit
    /// 402s via `handleAPIError`, the Week tab's limit-reached prompt —
    /// is dead in one place instead of needing to be gated individually.
    func presentPaywall(_ reason: PaywallReason) {
        guard MonetizationFlags.paywallEnabled else { return }
        pendingPaywall = reason
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
