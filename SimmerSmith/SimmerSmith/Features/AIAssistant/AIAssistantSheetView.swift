import SwiftUI
import SimmerSmithKit

struct AIAssistantSheetView: View {
    @Environment(AIAssistantCoordinator.self) private var coordinator
    @Environment(AppState.self) private var appState
    @FocusState private var composerFocused: Bool

    var body: some View {
        @Bindable var coord = coordinator

        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: SMSpacing.md) {
                            if coordinator.currentMessages.isEmpty {
                                emptyState
                            } else {
                                ForEach(coordinator.currentMessages) { message in
                                    AssistantMessageInlineBubble(message: message)
                                        .id(message.messageId)
                                }
                            }
                            if coordinator.isSending {
                                HStack(spacing: SMSpacing.sm) {
                                    ProgressView().controlSize(.small).tint(SMColor.aiPurple)
                                    Text("Thinking…")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                                .padding(.horizontal, SMSpacing.md)
                            }
                            if !coordinator.errorMessage.isEmpty {
                                Text(coordinator.errorMessage)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.destructive)
                                    .padding(.horizontal, SMSpacing.md)
                            }
                        }
                        .padding(.vertical, SMSpacing.md)
                    }
                    .onChange(of: coordinator.currentMessages.last?.messageId) { _, newValue in
                        if let newValue {
                            withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composer
            }
            .navigationTitle("AI Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        coordinator.startNewConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(SMColor.primary)
                    }
                    .accessibilityLabel("New conversation")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { coordinator.dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.fraction(1.0 / 3.0), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(1.0 / 3.0)))
        .presentationDragIndicator(.visible)
    }

    private var emptyState: some View {
        VStack(spacing: SMSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(SMColor.aiPurple.opacity(0.85))
            Text(emptyStateTitle)
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textPrimary)
                .multilineTextAlignment(.center)
            Text(emptyStateHint)
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
            suggestionChips
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SMSpacing.xl)
        .padding(.horizontal, SMSpacing.lg)
    }

    private var emptyStateTitle: String {
        guard let context = coordinator.currentContext else { return "Ask me anything" }
        switch context.pageType {
        case "week":
            return "Let's tune this week"
        case "recipe_detail":
            return "Questions about this recipe?"
        case "recipes":
            return "Browsing recipes"
        case "grocery":
            return "Grocery assistant"
        case "settings":
            return "Settings help"
        default:
            return "Ask me anything"
        }
    }

    private var emptyStateHint: String {
        guard let context = coordinator.currentContext else {
            return "I can plan your week, swap meals, rebalance macros, and more."
        }
        switch context.pageType {
        case "week":
            return "Try \"plan this week\", \"swap Tuesday dinner for fish\", or \"make Wednesday higher protein\"."
        case "recipe_detail":
            return "Try \"make this lower carb\" or \"substitute the cream\"."
        case "recipes":
            return "Try \"find me a 30-minute dinner\" or \"what should I cook with chicken?\""
        case "grocery":
            return "Try \"fetch Kroger prices\" or \"what else do I need for Tuesday?\""
        default:
            return "I can plan your week, swap meals, rebalance macros, and more."
        }
    }

    @ViewBuilder
    private var suggestionChips: some View {
        let suggestions = contextualSuggestions
        if !suggestions.isEmpty {
            VStack(spacing: SMSpacing.sm) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        coordinator.composerText = suggestion
                        Task { await coordinator.sendMessage(suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SMSpacing.md)
                            .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, SMSpacing.sm)
        }
    }

    private var contextualSuggestions: [String] {
        guard let context = coordinator.currentContext else {
            return ["Plan this week", "What can I make with chicken?"]
        }
        switch context.pageType {
        case "week":
            if let day = context.focusDayName {
                return [
                    "Swap \(day) dinner for something lighter",
                    "Make \(day) higher protein",
                    "Replan \(day) to hit my macros"
                ]
            }
            return [
                "Plan this week",
                "Make the week higher protein",
                "Swap Tuesday dinner for something lighter"
            ]
        case "recipe_detail":
            if let name = context.recipeName {
                return [
                    "Make \(name) lower carb",
                    "Can I substitute the cream?",
                    "Add this to the week"
                ]
            }
            return []
        case "recipes":
            return ["Find me a quick weeknight dinner", "What should I cook with salmon?"]
        case "grocery":
            return ["Fetch Kroger prices", "What can I skip?"]
        default:
            return []
        }
    }

    @ViewBuilder
    private var contextChip: some View {
        if let context = coordinator.currentContext, !context.pageLabel.isEmpty {
            HStack(spacing: SMSpacing.xs) {
                Image(systemName: iconForPage(context.pageType))
                    .font(.caption2)
                Text(context.pageLabel)
                    .font(SMFont.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(SMColor.textTertiary)
            .padding(.horizontal, SMSpacing.sm)
            .padding(.vertical, 4)
        }
    }

    private func iconForPage(_ type: String) -> String {
        switch type {
        case "week": return "calendar"
        case "recipe_detail": return "book.closed"
        case "recipes": return "books.vertical"
        case "grocery": return "cart"
        case "settings": return "gear"
        default: return "sparkles"
        }
    }

    private var composer: some View {
        @Bindable var coord = coordinator

        return VStack(spacing: 0) {
            SMColor.divider.frame(height: 1)
            contextChip
            HStack(alignment: .bottom, spacing: SMSpacing.md) {
                TextField("Ask about this screen…", text: $coord.composerText, axis: .vertical)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(1...5)
                    .padding(SMSpacing.md)
                    .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .focused($composerFocused)

                Button {
                    let text = coord.composerText
                    Task { await coordinator.sendMessage(text) }
                } label: {
                    if coordinator.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(SMColor.primary)
                    }
                }
                .disabled(
                    coordinator.isSending
                    || coord.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.top, SMSpacing.sm)
            .padding(.bottom, SMSpacing.md)
            .background(SMColor.surfaceElevated)
        }
    }
}

private struct AssistantMessageInlineBubble: View {
    let message: AssistantMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: SMSpacing.xs) {
            if !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    ForEach(message.toolCalls) { call in
                        AssistantToolCallCard(call: call)
                    }
                }
            }
            if !displayText.isEmpty {
                Text(displayText)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .padding(SMSpacing.md)
                    .background(
                        isUser ? AnyShapeStyle(SMColor.primary.opacity(0.15))
                               : AnyShapeStyle(SMColor.surfaceElevated),
                        in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                    )
                    .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, SMSpacing.md)
    }

    private var displayText: String {
        let trimmed = message.contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if message.status == "streaming" { return "…" }
        let errorText = message.error.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty { return "Failed: \(errorText)" }
        return ""
    }
}
