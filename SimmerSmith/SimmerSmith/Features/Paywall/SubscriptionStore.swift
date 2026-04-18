import Foundation
import Observation
import StoreKit
import SimmerSmithKit

/// StoreKit 2 wrapper. Keeps a local source of truth for "is the user Pro
/// on this device right now?" while the SimmerSmith backend holds the
/// authoritative answer (synced via `AppState.refreshAll` after
/// `verifySubscriptionTransaction`).
@MainActor
@Observable
final class SubscriptionStore {
    static let monthlyProductId = "simmersmith.pro.monthly"
    static let annualProductId = "simmersmith.pro.annual"
    static let productIds: [String] = [monthlyProductId, annualProductId]

    /// Whichever StoreKit tells us is currently entitled. Updated via
    /// `Transaction.currentEntitlements` on launch and whenever a purchase
    /// or renewal completes.
    var isEntitled: Bool = false

    /// Loaded products in the order we want to render them (monthly first).
    var products: [Product] = []

    /// Latest signed transaction JWS we've received. The caller ships this
    /// to the backend via `APIClient.verifySubscriptionTransaction`.
    var lastSignedTransaction: String?

    /// A human-readable error message from the most recent purchase
    /// attempt — cleared when a purchase succeeds.
    var purchaseErrorMessage: String?

    /// True while a purchase or restore flow is running.
    var isPurchasing: Bool = false

    private var updateListenerTask: Task<Void, Never>?

    func start() async {
        await loadProducts()
        await refreshEntitlements()
        updateListenerTask?.cancel()
        updateListenerTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await self.applyVerifiedTransaction(transaction, jws: update.jwsRepresentation)
                }
            }
        }
    }

    func stop() {
        updateListenerTask?.cancel()
        updateListenerTask = nil
    }

    /// Fetches the two Pro products. Silently no-ops if StoreKit can't
    /// reach App Store Connect (e.g. before the products are approved);
    /// the paywall renders a "not available" state in that case.
    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIds)
            // Preserve our intended order instead of StoreKit's arbitrary one.
            products = Self.productIds.compactMap { id in
                loaded.first { $0.id == id }
            }
        } catch {
            purchaseErrorMessage = "Couldn't load subscription options: \(error.localizedDescription)"
        }
    }

    /// Refresh the local `isEntitled` flag from the StoreKit local cache.
    /// Called at launch before talking to the backend so the UI doesn't
    /// flash "free" for a beat.
    func refreshEntitlements() async {
        var entitled = false
        var latestJWS: String?
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let txn) = entitlement,
               Self.productIds.contains(txn.productID),
               (txn.expirationDate ?? .distantFuture) > Date() {
                entitled = true
                latestJWS = entitlement.jwsRepresentation
            }
        }
        isEntitled = entitled
        if let latestJWS {
            lastSignedTransaction = latestJWS
        }
    }

    /// Initiate a purchase for the given product. Returns the JWS string
    /// on success so the caller can hand it to the backend `/verify`
    /// endpoint. Returns nil when the user cancels or StoreKit rejects.
    @discardableResult
    func purchase(_ product: Product) async -> String? {
        purchaseErrorMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await applyVerifiedTransaction(transaction, jws: verification.jwsRepresentation)
                    await transaction.finish()
                    return verification.jwsRepresentation
                } else {
                    purchaseErrorMessage = "App Store could not verify the transaction."
                    return nil
                }
            case .userCancelled:
                return nil
            case .pending:
                purchaseErrorMessage = "Purchase is pending approval — we'll unlock Pro automatically once it clears."
                return nil
            @unknown default:
                return nil
            }
        } catch {
            purchaseErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// "Restore Purchases" UX. Syncs StoreKit transactions from the Apple
    /// ID signed into the App Store on this device. After the sync,
    /// `refreshEntitlements` pulls the restored transaction into state.
    @discardableResult
    func restore() async -> String? {
        purchaseErrorMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            return lastSignedTransaction
        } catch {
            purchaseErrorMessage = "Restore failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func applyVerifiedTransaction(_ transaction: Transaction, jws: String) async {
        if Self.productIds.contains(transaction.productID),
           (transaction.expirationDate ?? .distantFuture) > Date() {
            isEntitled = true
            lastSignedTransaction = jws
        }
    }
}
