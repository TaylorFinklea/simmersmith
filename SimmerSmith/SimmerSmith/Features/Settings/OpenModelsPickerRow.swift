import SwiftUI
import AIProviderKit

// SP-C / OpenRouter — the Settings → AI "Model" dropdown for the open-models provider
// entry (labeled "OpenRouter"). OpenRouter is an OpenAI-compatible META-provider modeled
// as `OpenModelVendor.openRouter`; the direct GLM/Kimi/MiniMax vendors stay in the code
// (ProviderRegistry) but are hidden from this picker. Options are a curated slug list
// (the descriptor's `fallbackModels`) plus a trailing "Custom…" row that reveals a
// free-text field for any OpenRouter slug. Selecting a row pins the vendor to OpenRouter
// and sets the model draft.
struct OpenModelsPickerRow: View {
    @Environment(AppState.self) private var appState

    /// The single vendor this picker offers. GLM/Kimi/MiniMax are hidden (replaced).
    private static let vendor: OpenModelVendor = .openRouter

    /// True while the user picked "Custom…" and is typing a slug the catalog doesn't list.
    @State private var isEditingCustom = false

    /// Sentinel tag for the "Custom…" row — namespaced so it can't collide with a slug.
    private static let customTag = "__simmersmith_custom_openrouter_model__"

    private var model: String {
        appState.aiOpenModelsModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var keychainID: String { ProviderRegistry.descriptor(for: Self.vendor).keychainKeyID }

    /// Curated slug options (descriptor fallback) plus the saved value; live fetch is
    /// off for OpenRouter (`modelsURL` is nil) so this is the curated list + Custom…
    private var options: [String] {
        AIModelCatalog.displayOptions(
            provider: keychainID,
            available: appState.ckAIModelOptions[keychainID] ?? [],
            saved: model
        )
    }

    /// Set both the pinned vendor and the model draft in one shot.
    private func setModel(_ value: String) {
        appState.aiOpenModelsVendorDraft = Self.vendor.rawValue
        appState.aiOpenModelsModelDraft = value
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if isEditingCustom { return Self.customTag }
                return model.isEmpty ? ProviderRegistry.descriptor(for: Self.vendor).defaultModel : model
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

    var body: some View {
        Picker("Model", selection: selection) {
            ForEach(options, id: \.self) { m in
                Text(m).tag(m)
            }
            Text("Custom…").tag(Self.customTag)
        }

        if isEditingCustom {
            TextField("OpenRouter model slug (e.g. z-ai/glm-4.6)", text: customFieldBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
