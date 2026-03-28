import SwiftUI
import SimmerSmithKit

struct AssistantView: View {
    @Environment(AppState.self) private var appState

    @State private var path: [String] = []
    @State private var launchContexts: [String: AppState.AssistantLaunchContext] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if appState.assistantThreads.isEmpty {
                    ContentUnavailableView(
                        "No Assistant Chats Yet",
                        systemImage: "sparkles.rectangle.stack",
                        description: Text("Start a new chat to create recipes, refine drafts, or ask cooking questions.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(appState.assistantThreads) { thread in
                        NavigationLink(value: thread.threadId) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(thread.title)
                                    .font(.headline)
                                if !thread.preview.isEmpty {
                                    Text(thread.preview)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task {
                                    try? await appState.deleteAssistantThread(threadID: thread.threadId)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Assistant")
            .navigationDestination(for: String.self) { threadID in
                AssistantThreadView(
                    threadID: threadID,
                    launchContext: launchContexts[threadID]
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BrandToolbarBadge()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            do {
                                let thread = try await appState.createAssistantThread()
                                launchContexts[thread.threadId] = AppState.AssistantLaunchContext(
                                    threadID: thread.threadId,
                                    initialText: "",
                                    attachedRecipeID: nil,
                                    attachedRecipeDraft: nil,
                                    intent: "general"
                                )
                                path = [thread.threadId]
                            } catch {
                                appState.lastErrorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .task {
                await appState.refreshAssistantThreads()
                handleLaunchContextIfNeeded()
            }
            .onChange(of: appState.assistantLaunchContext?.threadID) { _, _ in
                handleLaunchContextIfNeeded()
            }
        }
    }

    private func handleLaunchContextIfNeeded() {
        guard let launchContext = appState.consumeAssistantLaunchContext() else { return }
        launchContexts[launchContext.threadID] = launchContext
        path = [launchContext.threadID]
    }
}

private struct AssistantThreadView: View {
    @Environment(AppState.self) private var appState

    let threadID: String
    let launchContext: AppState.AssistantLaunchContext?

    @State private var composerText = ""
    @State private var attachedRecipeID: String?
    @State private var attachedRecipeDraft: RecipeDraft?
    @State private var intent: String = "general"
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var didApplyLaunchContext = false

    private var thread: AssistantThread? {
        appState.assistantThreadDetails[threadID]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let contextLabel {
                    Text(contextLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                }

                if let thread {
                    if thread.messages.isEmpty {
                        quickPrompts
                    } else {
                        ForEach(thread.messages) { message in
                            AssistantMessageBubble(message: message) { draft in
                                editorContext = RecipeEditorSheetContext(
                                    title: "Recipe Draft",
                                    draft: draft
                                )
                            }
                        }
                    }
                } else if appState.assistantSendingThreadIDs.contains(threadID) {
                    ProgressView("Preparing assistant…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ProgressView("Loading conversation…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }

                if let error = appState.assistantErrorByThreadID[threadID], !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 120)
        }
        .navigationTitle(thread?.title ?? "Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .task(id: threadID) {
            if appState.assistantThreadDetails[threadID] == nil {
                try? await appState.fetchAssistantThread(threadID: threadID)
            }
            applyLaunchContextIfNeeded()
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in }
        }
    }

    private var quickPrompts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try one of these")
                .font(.headline)
                .padding(.horizontal)
            ForEach(quickPromptItems, id: \.title) { prompt in
                Button {
                    composerText = prompt.text
                    intent = prompt.intent
                    Task { await sendMessage() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.title)
                            .font(.body.weight(.medium))
                        Text(prompt.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
        .padding(.top, 20)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask for a recipe, substitution, or cooking help", text: $composerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await sendMessage() }
                } label: {
                    if appState.assistantSendingThreadIDs.contains(threadID) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                    }
                }
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.assistantSendingThreadIDs.contains(threadID))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.thinMaterial)
        }
    }

    private var contextLabel: String? {
        if let draft = attachedRecipeDraft {
            return "Attached draft: \(draft.name)"
        }
        if let attachedRecipeID, let recipe = appState.recipes.first(where: { $0.recipeId == attachedRecipeID }) {
            return "Attached recipe: \(recipe.name)"
        }
        return nil
    }

    private var quickPromptItems: [(title: String, text: String, intent: String)] {
        [
            ("Create a recipe from scratch", "Create a weeknight dinner recipe with clear ingredients and steps.", "recipe_creation"),
            ("Help me fix a recipe", "Help me troubleshoot why this recipe turned out watery and what to change next time.", "recipe_refinement"),
            ("Explain a cooking term", "What does lukewarm milk mean and how do I do that?", "cooking_help"),
            ("Suggest sides or sauces", "Suggest a side and a sauce that would go well with this meal.", "general"),
        ]
    }

    private func applyLaunchContextIfNeeded() {
        guard !didApplyLaunchContext else { return }
        guard let launchContext else { return }
        composerText = launchContext.initialText
        attachedRecipeID = launchContext.attachedRecipeID
        attachedRecipeDraft = launchContext.attachedRecipeDraft
        intent = launchContext.intent
        didApplyLaunchContext = true
    }

    private func sendMessage() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        do {
            try await appState.sendAssistantMessage(
                threadID: threadID,
                text: text,
                attachedRecipeID: attachedRecipeID,
                attachedRecipeDraft: attachedRecipeDraft,
                intent: intent
            )
        } catch {
            appState.assistantErrorByThreadID[threadID] = error.localizedDescription
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantMessage
    let openDraft: (RecipeDraft) -> Void

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.contentMarkdown.isEmpty && message.status == "streaming" ? "Thinking…" : message.contentMarkdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let recipeDraft = message.recipeDraft {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recipeDraft.name)
                            .font(.headline)
                        if !recipeDraft.cuisine.isEmpty || !recipeDraft.mealType.isEmpty {
                            Text([recipeDraft.mealType.capitalized, recipeDraft.cuisine].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Open In Editor") {
                            openDraft(recipeDraft)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .padding()
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 520, alignment: message.role == "user" ? .trailing : .leading)

            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
        .padding(.horizontal)
    }

    private var bubbleBackground: some ShapeStyle {
        message.role == "user" ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.thinMaterial)
    }
}
