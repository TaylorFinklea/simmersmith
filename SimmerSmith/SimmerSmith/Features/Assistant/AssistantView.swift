import SwiftUI
import SimmerSmithKit

struct AssistantView: View {
    @Environment(AppState.self) private var appState

    @State private var path: [String] = []
    @State private var launchContexts: [String: AppState.AssistantLaunchContext] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                List {
                    if appState.assistantThreads.isEmpty && !appState.assistantExecutionAvailable {
                        ContentUnavailableView(
                            "Assistant Needs Setup",
                            systemImage: "sparkles.slash",
                            description: Text(appState.assistantExecutionStatusText)
                        )
                        .listRowBackground(Color.clear)
                    } else if appState.assistantThreads.isEmpty {
                        VStack(spacing: SMSpacing.xl) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 56))
                                .foregroundStyle(SMColor.aiPurple.opacity(0.8))

                            VStack(spacing: SMSpacing.sm) {
                                Text("AI Meal Assistant")
                                    .font(SMFont.display)
                                    .foregroundStyle(SMColor.textPrimary)

                                Text("Ask me to plan meals, create recipes, or answer cooking questions.")
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.textSecondary)
                                    .multilineTextAlignment(.center)
                            }

                            VStack(spacing: SMSpacing.sm) {
                                ForEach(emptyStatePrompts, id: \.self) { prompt in
                                    Button {
                                        Task {
                                            do {
                                                let thread = try await appState.createAssistantThread()
                                                launchContexts[thread.threadId] = AppState.AssistantLaunchContext(
                                                    threadID: thread.threadId,
                                                    initialText: prompt,
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
                                        HStack(spacing: SMSpacing.md) {
                                            Text(prompt)
                                                .font(SMFont.body)
                                                .foregroundStyle(SMColor.textPrimary)
                                                .multilineTextAlignment(.leading)
                                            Spacer()
                                            Image(systemName: "arrow.right.circle")
                                                .foregroundStyle(SMColor.primary)
                                        }
                                        .padding(SMSpacing.lg)
                                        .background(SMColor.surfaceCard)
                                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!appState.assistantExecutionAvailable)
                                }
                            }
                            .padding(.horizontal, SMSpacing.sm)
                        }
                        .padding(.vertical, SMSpacing.xxl)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(appState.assistantThreads) { thread in
                            NavigationLink(value: thread.threadId) {
                                HStack(alignment: .top, spacing: SMSpacing.md) {
                                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                                        Text(thread.title)
                                            .font(SMFont.subheadline)
                                            .foregroundStyle(SMColor.textPrimary)
                                        if !thread.preview.isEmpty {
                                            Text(thread.preview)
                                                .font(SMFont.caption)
                                                .foregroundStyle(SMColor.textTertiary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: SMSpacing.sm)
                                    Text(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                }
                                .padding(.vertical, SMSpacing.sm)
                            }
                            .listRowBackground(SMColor.surfaceCard)
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
                .scrollContentBackground(.hidden)
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
                            .foregroundStyle(SMColor.primary)
                    }
                    .accessibilityLabel("New chat thread")
                    .disabled(!appState.assistantExecutionAvailable)
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

    private var emptyStatePrompts: [String] {
        [
            "Plan this week's dinners",
            "Quick healthy lunch ideas",
            "What can I make with chicken and rice?",
        ]
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
        ZStack {
            SMColor.surface.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: SMSpacing.lg) {
                    if let contextLabel {
                        Text(contextLabel)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                            .padding(.horizontal)
                            .padding(.top, SMSpacing.sm)
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
                        ProgressView("Preparing assistant\u{2026}")
                            .foregroundStyle(SMColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ProgressView("Loading conversation\u{2026}")
                            .foregroundStyle(SMColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }

                    if let error = appState.assistantErrorByThreadID[threadID], !error.isEmpty {
                        Text(error)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.destructive)
                            .padding(.horizontal)
                    }
                }
                .padding(.bottom, 120)
            }
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
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            Text("Try one of these")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
                .padding(.horizontal)
            ForEach(quickPromptItems, id: \.title) { prompt in
                Button {
                    composerText = prompt.text
                    intent = prompt.intent
                    Task { await sendMessage() }
                } label: {
                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                        Text(prompt.title)
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textPrimary)
                        Text(prompt.text)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SMSpacing.lg)
                    .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!appState.assistantExecutionAvailable)
                .padding(.horizontal)
            }
        }
        .padding(.top, SMSpacing.xl)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            SMColor.divider.frame(height: 1)
            if !appState.assistantExecutionAvailable {
                Text(appState.assistantExecutionStatusText)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.top, SMSpacing.sm)
            }
            HStack(alignment: .bottom, spacing: SMSpacing.md) {
                TextField("Ask for a recipe, substitution, or cooking help", text: $composerText, axis: .vertical)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(1...5)
                    .padding(SMSpacing.md)
                    .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))

                Button {
                    Task { await sendMessage() }
                } label: {
                    if appState.assistantSendingThreadIDs.contains(threadID) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(SMColor.primary)
                    }
                }
                .disabled(
                    !appState.assistantExecutionAvailable ||
                    composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    appState.assistantSendingThreadIDs.contains(threadID)
                )
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.top, SMSpacing.sm)
            .padding(.bottom, SMSpacing.md)
            .background(SMColor.surfaceElevated)
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

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: SMSpacing.sm) {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                if !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        ForEach(message.toolCalls) { call in
                            AssistantToolCallCard(call: call)
                        }
                    }
                }
                Text(displayText)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let recipeDraft = message.recipeDraft {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        Text(recipeDraft.name)
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textPrimary)
                        if !recipeDraft.cuisine.isEmpty || !recipeDraft.mealType.isEmpty {
                            Text([recipeDraft.mealType.capitalized, recipeDraft.cuisine].filter { !$0.isEmpty }.joined(separator: " \u{2022} "))
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                        let ingredientCount = recipeDraft.ingredients.count
                        if ingredientCount > 0 {
                            Text("\(ingredientCount) ingredient\(ingredientCount == 1 ? "" : "s")")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                        Button {
                            openDraft(recipeDraft)
                        } label: {
                            Text("Open In Editor")
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(SMSpacing.md)
                    .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
            }
            .padding(SMSpacing.lg)
            .background(
                isUser ? AnyShapeStyle(SMColor.primary.opacity(0.15)) : AnyShapeStyle(SMColor.surfaceElevated),
                in: RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous)
            )
            .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)

            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(SMColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal)
    }

    private var displayText: String {
        let trimmed = message.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let errorText = message.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty {
            return "Assistant request failed: \(errorText)"
        }
        if message.status == "streaming" {
            return "Thinking\u{2026}"
        }
        if message.recipeDraft != nil {
            return "I put together a draft recipe for you to review below."
        }
        return ""
    }
}
