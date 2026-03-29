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

            Section("AI") {
                if let capabilities = appState.aiCapabilities {
                    if let target = capabilities.defaultTarget {
                        LabeledContent("Default route") {
                            Text(target.providerKind == "mcp" ? (target.mcpServerName ?? "MCP") : (target.providerName ?? "Direct"))
                        }
                    } else {
                        Text(appState.assistantExecutionStatusText)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Preferred mode") {
                        Text(capabilities.preferredMode.capitalized)
                    }
                    LabeledContent("User override") {
                        Text(capabilities.userOverrideConfigured ? "Configured" : "Not configured")
                    }
                    ForEach(capabilities.availableProviders) { provider in
                        LabeledContent(provider.label) {
                            Text(provider.available ? provider.source.replacingOccurrences(of: "_", with: " ").capitalized : "Unavailable")
                                .foregroundStyle(provider.available ? .secondary : .tertiary)
                        }
                    }
                } else {
                    Text(appState.assistantExecutionStatusText)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Templates") {
                LabeledContent("Recipe templates") {
                    Text("\(appState.recipeTemplateCount)")
                }
                if let defaultTemplate = appState.recipeMetadata?.templates.first(where: { $0.templateId == appState.recipeMetadata?.defaultTemplateId }) {
                    LabeledContent("Default template") {
                        Text(defaultTemplate.name)
                    }
                } else {
                    Text("Template library syncs with recipe metadata.")
                        .foregroundStyle(.secondary)
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandToolbarBadge()
            }
        }
    }
}
