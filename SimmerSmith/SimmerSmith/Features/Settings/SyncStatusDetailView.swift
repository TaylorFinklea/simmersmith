#if canImport(CloudKit)
import SwiftUI
import HouseholdSync

/// simmersmith-qrt: the detail screen behind Settings → "iCloud Sync". Surfaces the raw
/// `SyncStatusCenter` inputs the row's one-line status is derived from — last success, pending
/// state, participant-join progress, and the last engine-level failure (with its user-facing
/// message + when it happened) — so a permanently-failed save or a stalled participant join is
/// no longer invisible.
struct SyncStatusDetailView: View {
    @Environment(AppState.self) private var appState

    private var inputs: SyncStatusInputs { appState.syncStatusCenter.inputs }
    private var derivation: SyncStatusDerivation { appState.syncStatusCenter.derivation }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status", value: derivation.statusLine)

                LabeledContent("Last synced") {
                    Text(lastSyncedText)
                        .foregroundStyle(SMColor.textSecondary)
                }

                LabeledContent("Pending changes") {
                    Text(inputs.pendingSaveCount > 0 ? "Waiting to sync" : "None")
                        .foregroundStyle(SMColor.textSecondary)
                }
            } header: {
                SmithSectionHeader("sync status")
            }

            Section {
                LabeledContent("State", value: participantJoinText)
            } header: {
                SmithSectionHeader("shared household")
            }

            if let failure = inputs.lastFailure {
                Section {
                    Text(failure.message)
                        .foregroundStyle(SMColor.textPrimary)
                    if let failedAt = inputs.lastFailureAt {
                        LabeledContent("When") {
                            Text(failedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                } header: {
                    SmithSectionHeader("last sync error")
                }
            }
        }
        .navigationTitle("iCloud Sync")
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = inputs.lastSyncedAt else { return "Never" }
        return lastSyncedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var participantJoinText: String {
        switch inputs.participantJoin {
        case .idle:
            return appState.isParticipant ? "Joined" : "Owner — not applicable"
        case .joining(let attempt, let maxAttempts):
            return "Joining — attempt \(attempt) of \(maxAttempts)"
        case .stalled:
            return "Still joining the shared household…"
        case .joined:
            return "Joined"
        }
    }
}
#endif
