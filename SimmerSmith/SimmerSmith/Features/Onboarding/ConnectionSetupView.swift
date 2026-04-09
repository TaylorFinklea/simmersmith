import SwiftUI

struct ConnectionSetupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image("BrandLockup")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, alignment: .leading)
                    Text("Connect this iPhone to your SimmerSmith server. The app keeps a local cache for offline reading, but the server remains the source of truth.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section("Server") {
                TextField("http://192.168.1.20:8080", text: $appState.serverURLDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                SecureField("Bearer token", text: $appState.authTokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if isPlainHTTPURL(appState.serverURLDraft) {
                    Label {
                        Text("Using http:// sends your bearer token in plaintext. Anyone on the same network can read it. Prefer https:// whenever possible.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Warning: bearer token will be sent in plaintext")
                }
            }

            Section {
                Button {
                    Task { await appState.saveConnectionDetails() }
                } label: {
                    Text("Save and Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Section("Status") {
                Text(appState.syncStatusText)
                    .foregroundStyle(.secondary)
                if let lastErrorMessage = appState.lastErrorMessage {
                    Text(lastErrorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Connect")
    }

    private func isPlainHTTPURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("https://") { return false }
        // Treat explicit http:// AND bare hostnames as plaintext, since
        // ConnectionSettingsStore.normalizeServerURL will default them to http.
        return trimmed.hasPrefix("http://") || !trimmed.contains("://")
    }
}
