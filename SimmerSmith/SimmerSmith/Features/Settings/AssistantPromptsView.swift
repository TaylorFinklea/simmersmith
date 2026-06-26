import SwiftUI
import SimmerSmithKit

// SP-C — Settings → AI → Assistant prompts. Lets the user customize the quick suggestion
// chips the AI assistant shows on each screen (Week, Recipe, Recipes, Grocery). Overrides
// persist per-user in the private plane (AppState.saveAssistantPrompts); an empty/reset
// screen falls back to the built-in defaults.

struct AssistantPromptsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                ForEach(AssistantPrompts.contexts) { ctx in
                    NavigationLink {
                        AssistantPromptEditorView(context: ctx)
                    } label: {
                        HStack {
                            Text(ctx.title)
                            Spacer()
                            Text(isCustom(ctx) ? "Custom" : "Default")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }
            } header: {
                SmithSectionHeader("assistant prompts")
            } footer: {
                Text("The quick suggestions the assistant offers on each screen. Tap a screen to edit them.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Assistant prompts")
    }

    private func isCustom(_ ctx: AssistantPromptContext) -> Bool {
        !(appState.assistantPromptOverrides[ctx.pageType] ?? []).isEmpty
    }
}

private struct AssistantPromptEditorView: View {
    @Environment(AppState.self) private var appState
    let context: AssistantPromptContext

    @State private var items: [PromptItem] = []
    @State private var newPrompt: String = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                ForEach($items) { $item in
                    TextField("Prompt", text: $item.text, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                }
                .onDelete { offsets in
                    items.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    items.move(fromOffsets: source, toOffset: destination)
                }
                if items.isEmpty {
                    Text("No prompts — the assistant shows the defaults here.")
                        .font(.footnote)
                        .foregroundStyle(SMColor.textSecondary)
                }
            } header: {
                Text("Prompts")
            } footer: {
                if let hint = context.tokenHint {
                    Text("Use \(hint) — it's filled in for the current screen.")
                        .font(.footnote)
                }
            }

            Section {
                HStack {
                    TextField("Add a prompt", text: $newPrompt, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                    Button("Add", action: addPrompt)
                        .disabled(newPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    // Setting items to the defaults makes `persist()` (via onChange) drop
                    // the override, since cleaned == defaults.
                    items = context.defaults.map { PromptItem(text: $0) }
                }
            }
        }
        .navigationTitle(context.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onAppear {
            guard !loaded else { return }
            let current = appState.assistantPromptOverrides[context.pageType] ?? context.defaults
            items = current.map { PromptItem(text: $0) }
            loaded = true
        }
        // Persist on EVERY change (text edits included), not just structural ones, so an
        // in-flight edit isn't lost if the user backgrounds the app or swipes Settings away.
        .onChange(of: items) { _, _ in
            guard loaded else { return }
            persist()
        }
        .onDisappear(perform: persist)
    }

    private func addPrompt() {
        let trimmed = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(PromptItem(text: trimmed))
        newPrompt = ""
    }

    private func persist() {
        appState.saveAssistantPrompts(pageType: context.pageType, prompts: items.map(\.text))
    }
}

private struct PromptItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
}
