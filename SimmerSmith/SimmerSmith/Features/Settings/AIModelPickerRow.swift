import SwiftUI
import AIProviderKit

// SP-C — the Settings → AI "Model" dropdown. Replaces the old free-text model
// field. Options come from `AppState.ckAIModelOptions[key]` (the provider's live
// /v1/models, curated, or the static fallback). A "Custom…" row reveals a
// free-text field so a brand-new model the catalog doesn't list can still be pinned.
//
// `provider` is the selected text provider ("openai" | "anthropic"). The picker
// drives `AppState.aiOpenAIModelDraft` / `aiAnthropicModelDraft`; "Save AI Settings"
// persists it (empty draft → the provider default at resolve time).
struct AIModelPickerRow: View {
    @Environment(AppState.self) private var appState
    let provider: String

    /// True while the user has explicitly chosen "Custom…" and is typing a model
    /// the catalog doesn't list. Reset whenever the provider changes.
    @State private var isEditingCustom = false

    /// Sentinel tag for the "Custom…" row — namespaced so it can't collide with a
    /// real model ID.
    private static let customTag = "__simmersmith_custom_model__"

    /// Normalized provider key. Not every hydration path lowercases the stored
    /// provider, so normalize once here — field routing, the options lookup, the
    /// catalog, and the fetch all key off this.
    private var key: String { provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private var savedDraft: String {
        key == "anthropic" ? appState.aiAnthropicModelDraft : appState.aiOpenAIModelDraft
    }

    private func setDraft(_ value: String) {
        if key == "anthropic" {
            appState.aiAnthropicModelDraft = value
        } else {
            appState.aiOpenAIModelDraft = value
        }
    }

    /// The Picker rows — always non-empty (the fallback guarantees it), always
    /// containing the provider default and the saved value.
    private var options: [String] {
        AIModelCatalog.displayOptions(
            provider: key,
            available: appState.ckAIModelOptions[key] ?? [],
            saved: savedDraft
        )
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if isEditingCustom { return Self.customTag }
                let draft = savedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                // `options` always merges the saved draft and the default in, so a
                // non-empty draft is guaranteed to be a rendered row — return it
                // directly rather than re-deriving (and re-allocating) the list here.
                return draft.isEmpty ? AIModelCatalog.defaultModel(for: key) : draft
            },
            set: { newValue in
                if newValue == Self.customTag {
                    isEditingCustom = true
                } else {
                    isEditingCustom = false
                    setDraft(newValue)
                }
            }
        )
    }

    private var customFieldBinding: Binding<String> {
        Binding(get: { savedDraft }, set: { setDraft($0) })
    }

    /// Re-runs the model fetch when the provider changes or a key is saved for it
    /// (no-key → fallback only; keyed → live `/v1/models`).
    private var fetchKey: String {
        "\(key)|\(appState.providerAPIKeyConfigured(providerID: key))"
    }

    var body: some View {
        Picker("Model", selection: selection) {
            ForEach(options, id: \.self) { id in
                Text(id).tag(id)
            }
            Text("Custom…").tag(Self.customTag)
        }
        .task(id: fetchKey) {
            await appState.refreshCKAIModels(for: key)
        }
        .onChange(of: provider) { _, _ in
            // Provider flipped (openai ⇄ anthropic): drop back to the dropdown.
            isEditingCustom = false
        }

        if isEditingCustom {
            TextField(
                key == "anthropic"
                    ? "Anthropic model (e.g. claude-opus-4-5)"
                    : "OpenAI model (e.g. gpt-4o)",
                text: customFieldBinding
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }

        if appState.isFetchingAIModels[key] ?? false {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading available models…")
                    .font(.footnote)
                    .foregroundStyle(SMColor.textSecondary)
            }
        } else if let err = appState.ckAIModelFetchError[key] {
            Text("Showing default models — \(err)")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}
