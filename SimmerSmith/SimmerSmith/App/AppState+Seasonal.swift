import Foundation
import SimmerSmithKit

extension AppState {
    /// Fetches the in-season produce snapshot if we don't have one yet,
    /// or if the cached one is older than 6 hours. The AI-side caching
    /// (SP-D port: `AIService.fetchSeasonalProduce`) already keys by
    /// (region, year, month), so we don't need to be strict here — this
    /// is just to avoid spamming the AI on every Week tab open.
    func refreshSeasonalProduceIfStale() async {
        if let fetchedAt = seasonalProduceFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 6 * 60 * 60 {
            return
        }
        do {
            let items = try await fetchSeasonalProduceItems()
            seasonalProduce = items
            seasonalProduceFetchedAt = Date()
        } catch {
            // Silent fail — the strip just stays empty if AI is offline
            // or the user hasn't configured a region.
            seasonalProduce = []
        }
    }

    /// SP-D port: on-device AI call via `SeasonalPrompt`, when a household session
    /// (and its `AIService`) is live; falls back to Fly otherwise. Region resolves
    /// from the private-plane `ProfileRepository` first (CloudKit world), then the
    /// Fly profile snapshot, defaulting to "United States" — mirrors
    /// `seasonal_ai.seasonal_produce`'s `region or _DEFAULT_REGION`.
    private func fetchSeasonalProduceItems() async throws -> [InSeasonItem] {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let region = currentUserRegion()
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let wire = try await aiSvc.fetchSeasonalProduce(region: region, year: year, month: month)
        return wire.map { InSeasonItem(name: $0.name, whyNow: $0.whyNow, peakScore: $0.peakScore) }
        #else
        return try await apiClient.fetchSeasonalProduce()
        #endif
    }

    /// The user's region setting, defaulting to "United States" (mirrors
    /// `seasonal_ai._DEFAULT_REGION`).
    private func currentUserRegion() -> String {
        let raw: String
        #if canImport(CloudKit)
        if let v = profileRepository?.settings["user_region"], !v.isEmpty {
            raw = v
        } else {
            raw = profile?.settings["user_region"] ?? ""
        }
        #else
        raw = profile?.settings["user_region"] ?? ""
        #endif
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "United States" : trimmed
    }

    func forceRefreshSeasonalProduce() async {
        seasonalProduceFetchedAt = nil
        await refreshSeasonalProduceIfStale()
    }

    /// Persist the user's region setting and immediately re-fetch the
    /// in-season list since the cache key includes the region.
    func saveUserRegion(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.setSetting("user_region", trimmed)
            userRegionDraft = trimmed
            await forceRefreshSeasonalProduce()
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
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
