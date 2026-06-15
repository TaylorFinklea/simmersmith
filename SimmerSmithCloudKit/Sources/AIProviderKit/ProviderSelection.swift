import Foundation

/// Decides which tier serves a feature, given what's available on this device.
/// The policy realizes SP-A §7.2: light tasks default on-device; heavy reasoning
/// (week-gen etc.) defaults to the cloud on iOS 26 (on-device for heavy tasks is
/// gated on Spike 2 at iOS 27 GA). Pure + deterministic → fully unit-testable.
public struct ProviderRouter: Sendable {
    /// Foundation Models usable on this device (capable hardware + enabled).
    public var onDeviceAvailable: Bool
    /// The user supplied a key for at least one cloud model (in the Keychain).
    public var byoKey: CloudModel?
    /// The credits gateway is reachable / the user bought credits.
    public var creditsAvailable: Bool
    /// Opt-in: allow heavy tasks on-device (off by default until Spike 2 clears it).
    public var allowOnDeviceHeavy: Bool

    public init(onDeviceAvailable: Bool, byoKey: CloudModel? = nil,
                creditsAvailable: Bool = false, allowOnDeviceHeavy: Bool = false) {
        self.onDeviceAvailable = onDeviceAvailable; self.byoKey = byoKey
        self.creditsAvailable = creditsAvailable; self.allowOnDeviceHeavy = allowOnDeviceHeavy
    }

    /// Resolve the tier, or nil when nothing can serve the feature.
    public func tier(for feature: AIFeature) -> AITier? {
        if feature.isHeavy {
            // Heavy: prefer a cloud frontier model; on-device only if explicitly allowed.
            if let model = byoKey { return .cloudBYOKey(model) }
            if creditsAvailable { return .creditsGateway }
            if allowOnDeviceHeavy && onDeviceAvailable { return .onDevice }
            return nil
        }
        // Light: prefer free on-device, then BYO-key, then credits.
        if onDeviceAvailable { return .onDevice }
        if let model = byoKey { return .cloudBYOKey(model) }
        if creditsAvailable { return .creditsGateway }
        return nil
    }
}
