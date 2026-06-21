import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
#endif

/// SP-C slice 5 — household term-alias state delegated to AliasRepository (household zone).
///
/// `AppState.householdAliases` is an @Observable stored property that views bind to.
/// Each method delegates to `aliasRepository` when the CloudKit session is ready,
/// then mirrors the repo's in-memory list onto `householdAliases` so views update.
extension AppState {
    func loadHouseholdAliases() async {
        #if canImport(CloudKit)
        guard let repo = aliasRepository else { return }
        repo.reload()
        householdAliases = repo.aliases
        #endif
    }

    @discardableResult
    func upsertHouseholdAlias(term: String, expansion: String, notes: String = "") async -> Bool {
        #if canImport(CloudKit)
        guard let repo = aliasRepository else { return false }
        let recordName = repo.upsertAlias(term: term, expansion: expansion, notes: notes)
        householdAliases = repo.aliases
        return !recordName.isEmpty
        #else
        return false
        #endif
    }

    func deleteHouseholdAlias(term: String) async {
        #if canImport(CloudKit)
        guard let repo = aliasRepository else { return }
        // The aliasId (det-keyed recordName) is "alias:<normalized_term>".
        let aliasId = "alias:\(term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))"
        repo.deleteAlias(aliasId: aliasId)
        householdAliases = repo.aliases
        #endif
    }
}
