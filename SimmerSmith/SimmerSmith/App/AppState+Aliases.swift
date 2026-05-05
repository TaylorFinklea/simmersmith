import Foundation
import SimmerSmithKit

/// M26 Phase 3 — per-household shorthand alias state + helpers.
///
/// Aliases live on `AppState` rather than fetched on-demand so the
/// Settings UI can render reactively. The fetch is cheap (one row per
/// alias — typically a handful per household) and only happens when
/// the user opens the AI section's "Custom terms" subsection.
extension AppState {
    func loadHouseholdAliases() async {
        do {
            householdAliases = try await apiClient.fetchHouseholdAliases()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func upsertHouseholdAlias(term: String, expansion: String, notes: String = "") async {
        do {
            let alias = try await apiClient.upsertHouseholdAlias(
                body: SimmerSmithAPIClient.HouseholdTermAliasUpsertBody(
                    term: term, expansion: expansion, notes: notes
                )
            )
            // Replace in-place if existing, otherwise append.
            if let idx = householdAliases.firstIndex(where: { $0.term == alias.term }) {
                householdAliases[idx] = alias
            } else {
                householdAliases.append(alias)
            }
            householdAliases.sort(by: { $0.term < $1.term })
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deleteHouseholdAlias(term: String) async {
        do {
            try await apiClient.deleteHouseholdAlias(term: term)
            householdAliases.removeAll(where: { $0.term == term })
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
