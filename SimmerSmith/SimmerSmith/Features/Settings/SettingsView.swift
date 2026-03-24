import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Server") {
                TextField("Server URL", text: $appState.serverURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                SecureField("Bearer token", text: $appState.authTokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save Connection") {
                    Task { await appState.saveConnectionDetails() }
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Sync") {
                Text(appState.syncStatusText)
                    .foregroundStyle(.secondary)

                if let updatedAt = appState.currentWeek?.updatedAt {
                    LabeledContent("Current week") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let updatedAt = appState.profile?.updatedAt {
                    LabeledContent("Profile") {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Button("Refresh Now") {
                    Task { await appState.refreshAll() }
                }
            }

            Section("Data") {
                Button("Clear Local Cache", role: .destructive) {
                    appState.clearLocalCache()
                }

                Button("Reset Connection", role: .destructive) {
                    appState.resetConnection()
                }
            }
        }
        .navigationTitle("Settings")
    }
}
