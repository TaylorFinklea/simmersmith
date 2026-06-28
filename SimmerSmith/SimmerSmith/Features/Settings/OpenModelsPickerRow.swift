import SwiftUI
import AIProviderKit

// SP-C — the Settings → AI "Model" dropdown for the single "Open models" provider
// entry. Unlike AIModelPickerRow (one provider), this spans all three open vendors
// (GLM/Z.ai, Kimi/Moonshot, MiniMax) in one Picker, sectioned by vendor. Selecting a
// row sets BOTH the vendor and the model draft — the chosen model determines which
// vendor key + base URL the app uses. Per-vendor options come from
// `ckAIModelOptions[<keychainID>]` (live /models curated, or the static fallback);
// only the selected vendor's live list is fetched (the others show their fallback).
struct OpenModelsPickerRow: View {
    @Environment(AppState.self) private var appState

    private var vendorRaw: String {
        appState.aiOpenModelsVendorDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var selectedVendor: OpenModelVendor? { OpenModelVendor(rawValue: vendorRaw) }
    private var model: String { appState.aiOpenModelsModelDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Composite Picker tag "vendor:model" so one selection carries both.
    private static func tag(_ v: OpenModelVendor, _ model: String) -> String { "\(v.rawValue):\(model)" }

    /// The keychain id whose live model list should be fetched (the selected vendor's).
    private var selectedKeychainID: String? {
        selectedVendor.map { ProviderRegistry.descriptor(for: $0).keychainKeyID }
    }

    private func options(for v: OpenModelVendor) -> [String] {
        let kc = ProviderRegistry.descriptor(for: v).keychainKeyID
        return AIModelCatalog.displayOptions(
            provider: kc,
            available: appState.ckAIModelOptions[kc] ?? [],
            saved: (selectedVendor == v) ? model : ""
        )
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                // Default to GLM's default model when nothing is selected yet.
                let v = selectedVendor ?? .glm
                let m = (selectedVendor == nil || model.isEmpty)
                    ? ProviderRegistry.descriptor(for: v).defaultModel
                    : model
                return Self.tag(v, m)
            },
            set: { composite in
                let parts = composite.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let v = OpenModelVendor(rawValue: parts[0]) else { return }
                appState.aiOpenModelsVendorDraft = v.rawValue
                appState.aiOpenModelsModelDraft = parts[1]
            }
        )
    }

    /// Refetch the selected vendor's live models when the vendor or its key changes.
    private var fetchKey: String {
        let kc = selectedKeychainID ?? ""
        return "\(kc)|\(appState.providerAPIKeyConfigured(providerID: kc))"
    }

    var body: some View {
        Picker("Model", selection: selection) {
            ForEach(OpenModelVendor.allCases, id: \.self) { v in
                Section(v.displayName) {
                    ForEach(options(for: v), id: \.self) { m in
                        Text(m).tag(Self.tag(v, m))
                    }
                }
            }
        }
        .task(id: fetchKey) {
            if let kc = selectedKeychainID, !kc.isEmpty {
                await appState.refreshCKAIModels(for: kc)
            }
        }

        if let kc = selectedKeychainID {
            if appState.isFetchingAIModels[kc] ?? false {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading available models…")
                        .font(.footnote)
                        .foregroundStyle(SMColor.textSecondary)
                }
            } else if let err = appState.ckAIModelFetchError[kc] {
                Text("Showing default models — \(err)")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }
}
