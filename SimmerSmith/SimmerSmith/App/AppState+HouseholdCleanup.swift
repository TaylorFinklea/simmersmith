import Foundation
#if canImport(CloudKit)
import CloudKitProvisioning
#endif

// simmersmith-auc — automatic cleanup of the leftover `household-*` zones that earlier builds'
// repeated orphan-minting left in the user's private database (13 of them on the reporting
// device). Discovery already picks the data-richest zone and ignores the rest, so these were
// harmless — but the app ANNOUNCED them on every launch ("Found 13 leftover empty household(s)
// from earlier builds — harmless") through `lastErrorMessage`, the error channel, warning
// triangle and all. A nag is not a fix. Delete them instead, and say nothing.
//
// The safety rules live in `HouseholdZoneProvisioner.classifyLeftovers` (pure, unit-tested);
// this is the wiring that decides WHEN the pass runs and what — if anything — reaches the UI.
extension AppState {
    /// Kick the cleanup pass, if discovery saw any leftovers. Fire-and-forget by design:
    ///
    ///   - It runs AFTER `householdLaunchPhase = .ready`, detached, so a hung CloudKit delete
    ///     can never hold the kitchen closed. Nothing downstream waits on the result.
    ///   - It no-ops in the steady state. One household zone → discovery returns early with no
    ///     ignored ids → `pendingLeftoverHouseholdIDs` is empty → not a single network call.
    ///   - It is owner-only by construction: the participant paths return before
    ///     `resolveHouseholdID()` ever runs, and the pass only touches the user's own private
    ///     database — a household you joined via a share lives in the SHARED database and is
    ///     never enumerated here.
    ///
    /// Clearing the ids up front makes a repeat call (a foreground retry re-booting the session)
    /// a no-op rather than a second concurrent pass over the same zones.
    func scheduleLeftoverHouseholdCleanup(keeping householdID: String) {
        guard !pendingLeftoverHouseholdIDs.isEmpty else { return }
        pendingLeftoverHouseholdIDs = []
        Task { [weak self] in
            await self?.cleanUpLeftoverHouseholds(keeping: householdID)
        }
    }

    /// The pass. Silent on success, silent on failure — the user asked for this to be cleaned
    /// up, not narrated, and a failure is genuinely nothing for them to act on: the delete is
    /// the last step, so a throw leaves every zone intact, and the pass is idempotent, so
    /// "retry next launch" is a complete recovery.
    ///
    /// The one thing that DOES reach the UI is a data-bearing leftover — a zone that censused
    /// cleanly and holds real records. That is a genuine fork rather than build residue, so it
    /// survives cleanup and surfaces in Settings. A zone we merely couldn't READ stays silent:
    /// a transient CloudKit hiccup must never masquerade as a fork (and it is retried next
    /// launch anyway).
    func cleanUpLeftoverHouseholds(keeping householdID: String) async {
        do {
            let outcome = try await HouseholdZoneProvisioner()
                .deleteEmptyHouseholdZones(keeping: householdID)

            forkedHouseholdIDs = outcome.dataBearingHouseholdIDs

            guard !outcome.isEmpty else { return }
            print("[AppState+HouseholdCleanup] deleted \(outcome.deletedHouseholdIDs.count) empty "
                + "household(s): \(outcome.deletedHouseholdIDs.joined(separator: ", ")) · "
                + "kept \(outcome.dataBearingHouseholdIDs.count) holding data · "
                + "\(outcome.unreadableHouseholdIDs.count) unreadable (retried next launch)")
        } catch {
            // Nothing was deleted — the delete is the last step and it throws as a unit. Stay
            // quiet and let the next launch retry.
            print("[AppState+HouseholdCleanup] cleanup failed, retrying next launch: \(error)")
        }
    }
}
