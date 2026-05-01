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
    func joinHousehold(code: String) async -> Bool {
        guard hasSavedConnection else { return false }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return false }
        do {
            currentHousehold = try await apiClient.joinHousehold(code: trimmed)
            // The joiner's data is now under a new household_id —
            // re-pull recipes, weeks, profile, etc. so the UI reflects
            // the merged state.
            await refreshAll()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Reset

    /// Called from `resetConnection` to clear household context on sign-out.
    func clearHouseholdContext() {
        currentHousehold = nil
    }
}
