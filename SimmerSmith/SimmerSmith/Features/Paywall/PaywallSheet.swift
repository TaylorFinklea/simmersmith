import SwiftUI
import StoreKit
import SimmerSmithKit

/// Bottom-sheet paywall. Shown whenever `AppState.pendingPaywall` is
/// non-nil — typically because a 402 came back from the backend or the
/// user tapped the "Upgrade to Pro" button in Settings.
struct PaywallSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let reason: PaywallReason

    private var store: SubscriptionStore { appState.subscriptionStore }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [SMColor.aiPurple.opacity(0.35), SMColor.surface],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: SMSpacing.xl) {
                        header

                        VStack(spacing: SMSpacing.md) {
                            ForEach(store.products, id: \.id) { product in
                                productCard(product)
                            }
                            if store.products.isEmpty {
                                Text("Subscription options aren't available right now. Please try again in a moment.")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(SMSpacing.md)
                            }
                        }

                        if let error = store.purchaseErrorMessage {
                            Text(error)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.destructive)
                                .multilineTextAlignment(.center)
                        }

                        HStack(spacing: SMSpacing.lg) {
                            Button("Restore Purchases") {
                                Task { await restore() }
                            }
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                            .disabled(store.isPurchasing)

                            Link("Terms", destination: URL(string: "https://simmersmith.fly.dev/privacy")!)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }

                        Text("Billed through Apple. Cancel anytime in Settings > Apple ID > Subscriptions.")
                            .font(.caption2)
                            .foregroundStyle(SMColor.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.xxl)
                }
            }
            .task { await store.start() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(spacing: SMSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(SMColor.aiPurple)

            Text("SimmerSmith Pro")
                .font(SMFont.display)
                .foregroundStyle(SMColor.textPrimary)

            Text(reason.headline)
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)

            featureList
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            featureRow(systemImage: "sparkles", text: "Unlimited AI week plans")
            featureRow(systemImage: "cart.fill", text: "Real Kroger prices, on demand")
            featureRow(systemImage: "wand.and.stars", text: "Rebalance any day to hit your macros")
            featureRow(systemImage: "book.closed", text: "Unlimited recipe imports")
        }
        .padding(.horizontal, SMSpacing.md)
    }

    private func featureRow(systemImage: String, text: String) -> some View {
        HStack(spacing: SMSpacing.md) {
            Image(systemName: systemImage)
                .foregroundStyle(SMColor.aiPurple)
                .frame(width: 24)
            Text(text)
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textPrimary)
            Spacer()
        }
    }

    private func productCard(_ product: Product) -> some View {
        let isAnnual = product.id == SubscriptionStore.annualProductId
        return Button {
            Task { await buy(product) }
        } label: {
            VStack(spacing: SMSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isAnnual ? "Annual" : "Monthly")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)
                    Spacer()
                    if isAnnual {
                        Text("Save ~33%")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, SMSpacing.xs)
                            .padding(.vertical, 2)
                            .background(SMColor.aiPurple.opacity(0.2), in: Capsule())
                            .foregroundStyle(SMColor.aiPurple)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(product.displayPrice)
                        .font(SMFont.display)
                        .foregroundStyle(SMColor.textPrimary)
                    Text(isAnnual ? "/year" : "/month")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                    Spacer()
                }
                if let intro = product.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
                    Text("\(intro.period.value)-\(periodLabel(intro.period.unit)) free trial")
                        .font(.caption)
                        .foregroundStyle(SMColor.aiPurple)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(SMSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                    .strokeBorder(isAnnual ? SMColor.aiPurple : SMColor.divider, lineWidth: isAnnual ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isPurchasing)
    }

    private func periodLabel(_ unit: Product.SubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return "period"
        }
    }

    private func buy(_ product: Product) async {
        guard let jws = await store.purchase(product) else { return }
        await verifyWithBackend(jws: jws)
    }

    private func restore() async {
        guard let jws = await store.restore() else {
            if !store.isEntitled && store.purchaseErrorMessage == nil {
                store.purchaseErrorMessage = "No active subscription found on this Apple ID."
            }
            return
        }
        await verifyWithBackend(jws: jws)
    }

    private func verifyWithBackend(jws: String) async {
        do {
            _ = try await appState.apiClient.verifySubscriptionTransaction(signedJWS: jws)
            await appState.refreshAll()
            if appState.isPro {
                dismiss()
            }
        } catch {
            store.purchaseErrorMessage = "Backend did not accept the purchase: \(error.localizedDescription)"
        }
    }
}

/// Reason the paywall was presented. Drives the headline copy so the user
/// understands what they lost access to.
enum PaywallReason: Identifiable, Equatable, Hashable {
    case manualUpgrade
    case limitReached(action: String, used: Int, limit: Int)

    var id: String {
        switch self {
        case .manualUpgrade: return "manual"
        case .limitReached(let action, _, _): return "limit:\(action)"
        }
    }

    var headline: String {
        switch self {
        case .manualUpgrade:
            return "Unlock unlimited AI, pricing, and macro rebalancing."
        case .limitReached(let action, _, let limit):
            switch action {
            case "ai_generate":
                return "You've used your \(limit) free AI plan this month. Pro gives you unlimited."
            case "pricing_fetch":
                return "You've used your \(limit) free pricing fetch this month. Pro gives you unlimited."
            case "rebalance_day":
                return "Rebalancing a day is a Pro feature — tap a plan to try it."
            case "recipe_import":
                return "You've hit the free recipe-import limit for this month."
            default:
                return "You've hit the free-tier limit. Upgrade to keep going."
            }
        }
    }
}
