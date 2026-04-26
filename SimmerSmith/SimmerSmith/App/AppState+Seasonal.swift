import Foundation
import SimmerSmithKit

extension AppState {
    /// Fetches the in-season produce snapshot if we don't have one yet,
    /// or if the cached one is older than 6 hours. Server-side caching
    /// already keys by (region, year, month), so we don't need to be
    /// strict here — this is just to avoid spamming the route on every
    /// Week tab open.
    func refreshSeasonalProduceIfStale() async {
        if let fetchedAt = seasonalProduceFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 6 * 60 * 60 {
            return
        }
        do {
            let items = try await apiClient.fetchSeasonalProduce()
            seasonalProduce = items
            seasonalProduceFetchedAt = Date()
        } catch {
            // Silent fail — the strip just stays empty if AI is offline
            // or the user hasn't configured a region.
            seasonalProduce = []
        }
    }

    func forceRefreshSeasonalProduce() async {
        seasonalProduceFetchedAt = nil
        await refreshSeasonalProduceIfStale()
    }

    /// Persist the user's region setting and immediately re-fetch the
    /// in-season list since the cache key includes the region.
    func saveUserRegion(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSavedConnection else { return }
        do {
            let updated = try await apiClient.updateProfile(settings: ["user_region": trimmed])
            profile = updated
            try? cacheStore.saveProfile(updated)
            userRegionDraft = trimmed
            await forceRefreshSeasonalProduce()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Hydrate `userRegionDraft` from a freshly-loaded profile so the
    /// Settings TextField shows the saved value on first render.
    func syncRegionDraft(from profile: ProfileSnapshot) {
        userRegionDraft = profile.settings["user_region"] ?? ""
    }
}
