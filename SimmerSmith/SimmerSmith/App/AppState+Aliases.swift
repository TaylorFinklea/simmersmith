import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
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
        // Use the SAME det-key builder that AliasRepository.upsertAlias uses
        // (RecordNames.termAlias) so create + delete share one key builder — no drift
        // from a hand-rolled normalization that could diverge from the canonical one.
        let aliasId = RecordNames.termAlias(term: term)
        repo.deleteAlias(aliasId: aliasId)
        householdAliases = repo.aliases
        #endif
    }
}
