import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Refresh

    /// Pull the current household snapshot. Best-effort: a network or
    /// 404 failure leaves `currentHousehold` unchanged so the Settings
    /// UI degrades gracefully on older builds without the route.
    func refreshHousehold() async {
        guard hasSavedConnection else { return }
        do {
            let snapshot = try await apiClient.fetchHousehold()
            currentHousehold = snapshot
        } catch {
            // Don't surface to lastErrorMessage — household refresh is
            // a side concern; the user shouldn't see a banner if the
            // call fails on bootstrap.
            print("[AppState+Household] refreshHousehold failed: \(error)")
        }
    }

    // MARK: - Mutations

    /// Owner-only: rename the household.
    func renameHousehold(_ name: String) async {
        guard hasSavedConnection else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            currentHousehold = try await apiClient.renameHousehold(name: trimmed)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Owner-only: mint a fresh invitation code. Returns the code so
    /// the caller can display it / share it. On failure surfaces the
    /// error and returns nil.
    func createHouseholdInvitation() async -> String? {
        guard hasSavedConnection else { return nil }
        do {
            let invitation = try await apiClient.createHouseholdInvitation()
            // Refresh the household so the active-invitations list
            // updates in Settings without a manual pull-to-refresh.
            await refreshHousehold()
            return invitation.code
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Owner-only: revoke an unclaimed invitation.
    func revokeHouseholdInvitation(code: String) async {
        guard hasSavedConnection else { return }
        do {
            try await apiClient.revokeHouseholdInvitation(code: code)
            await refreshHousehold()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Claim an invitation. After success, refresh the full app state so
    /// the joiner's UI reflects the merged household (their content +
    /// the inviter's content, all under the new shared household_id).
    /// HARD-GATED (household-sharing v1). The old Fly server-side merge fused two households
    /// by re-pointing the joiner's rows and deleting their solo household — exactly what the
    /// CloudKit ADOPT model forbids, and it never actually shared the live CloudKit data.
    /// Real two-account sharing now happens by accepting a zone-wide CKShare link (see
    /// `bootParticipantSession`). This is a deliberate no-op so a stray code-join can never
    /// merge or delete a household. The Settings caller has been removed.
    func joinHousehold(code: String) async -> Bool {
        lastErrorMessage = "Joining by code is no longer used — accept the share link your household owner sends from Settings instead."
        return false
    }

    // MARK: - Reset

    /// Called from `resetConnection` to clear household context on sign-out.
    func clearHouseholdContext() {
        currentHousehold = nil
        #if canImport(CloudKit)
        // SP-C Task 5 — tear down the CloudKit session and DELETE its durable
        // engine-state token so the next household signed in on this device does not
        // inherit the prior household's sync token (Task-3 token-leakage risk).
        teardownHouseholdSession()
        #endif
    }
}
