import SwiftUI
import AIProviderKit

// SP-C — the Settings → AI picker for the `openmodels` provider entry. The app
// keeps the internal provider tag (`openmodels`) while the visible vendor choices are
// Ollama Cloud and NeuralWatt. Each vendor maps to its own Keychain id +
// OpenAI-compatible endpoint through `ProviderRegistry`; the selected model determines
// which vendor key is used.
struct OpenModelsPickerRow: View {
    @Environment(AppState.self) private var appState

    /// True while the user picked "Custom…" and is typing a model slug/id the catalog
    /// doesn't list.
    @State private var isEditingCustom = false

    /// Sentinel tag for the "Custom…" row — namespaced so it can't collide with a model id.
    private static let customTag = "__simmersmith_custom_open_model__"

    private var visibleVendors: [OpenModelVendor] { ProviderRegistry.allOpenModelVendors }

    private var rawVendorDraft: String {
        appState.aiOpenModelsVendorDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleDraftVendor: OpenModelVendor? {
        guard let vendor = OpenModelVendor(rawValue: rawVendorDraft), visibleVendors.contains(vendor) else {
            return nil
        }
        return vendor
    }

    private var currentVendor: OpenModelVendor {
        visibleDraftVendor ?? .ollamaCloud
    }

    private var descriptor: ProviderDescriptor { ProviderRegistry.descriptor(for: currentVendor) }
    private var keychainID: String { descriptor.keychainKeyID }

    private var model: String {
        appState.aiOpenModelsModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Curated fallback or live `/models` options plus the saved value and provider default.
    private var options: [String] {
        AIModelCatalog.displayOptions(
            provider: keychainID,
            available: appState.ckAIModelOptions[keychainID] ?? [],
            saved: model
        )
    }

    private var vendorSelection: Binding<String> {
        Binding(
            get: { currentVendor.rawValue },
            set: { newValue in
                let next = visibleVendors.first { $0.rawValue == newValue } ?? .ollamaCloud
                appState.aiOpenModelsVendorDraft = next.rawValue
                appState.aiOpenModelsModelDraft = ProviderRegistry.descriptor(for: next).defaultModel
                isEditingCustom = false
            }
        )
    }

    /// Set both the vendor and the model draft in one shot so Save/Test/Clear route to
    /// the Keychain id for the currently selected vendor.
    private func setModel(_ value: String) {
        appState.aiOpenModelsVendorDraft = currentVendor.rawValue
        appState.aiOpenModelsModelDraft = value
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if isEditingCustom { return Self.customTag }
                return model.isEmpty ? descriptor.defaultModel : model
            },
            set: { newValue in
                if newValue == Self.customTag {
                    isEditingCustom = true
                } else {
                    isEditingCustom = false
                    setModel(newValue)
                }
            }
        )
    }

    private var customFieldBinding: Binding<String> {
        Binding(get: { appState.aiOpenModelsModelDraft }, set: { setModel($0) })
    }

    /// Re-runs the model fetch when the selected vendor changes or a key is saved for it
    /// (no-key → fallback only; keyed → live `/v1/models`).
    private var fetchKey: String {
        "\(keychainID)|\(appState.providerAPIKeyConfigured(providerID: keychainID))"
    }

    private func ensureVisibleDefaults() {
        if visibleDraftVendor == nil {
            appState.aiOpenModelsVendorDraft = OpenModelVendor.ollamaCloud.rawValue
        }
        if model.isEmpty {
            appState.aiOpenModelsModelDraft = ProviderRegistry.descriptor(for: currentVendor).defaultModel
        }
    }

    var body: some View {
        Picker("Open provider", selection: vendorSelection) {
            ForEach(visibleVendors, id: \.rawValue) { vendor in
                Text(vendor.displayName).tag(vendor.rawValue)
            }
        }
        .onAppear { ensureVisibleDefaults() }

        Picker("Model", selection: modelSelection) {
            ForEach(options, id: \.self) { model in
                Text(model).tag(model)
            }
            Text("Custom…").tag(Self.customTag)
        }
        .task(id: fetchKey) {
            ensureVisibleDefaults()
            await appState.refreshCKAIModels(for: keychainID)
        }
        .onChange(of: appState.aiOpenModelsVendorDraft) { _, _ in
            isEditingCustom = false
        }

        if isEditingCustom {
            TextField("\(currentVendor.displayName) model (e.g. \(descriptor.defaultModel))", text: customFieldBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }

        if appState.isFetchingAIModels[keychainID] ?? false {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading available models…")
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)
            }
        } else if let err = appState.ckAIModelFetchError[keychainID] {
            Text("Showing default models — \(err)")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}
