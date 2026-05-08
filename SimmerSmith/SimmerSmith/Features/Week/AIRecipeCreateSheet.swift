import SwiftUI
import SimmerSmithKit

/// Quick-add AI recipe shell. Generates a draft, then hands off to
/// `RecipeDraftReviewSheet` (M29 build 53) so the user can refine
/// or hand-edit before anything persists. Solves the "AI slop"
/// problem: pre-build-53 this sheet auto-saved every draft on its
/// own button tap, leaving abandoned recipes in the library after
/// each iteration.
struct AIRecipeCreateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mealName: String
    let onSaved: (RecipeSummary) async -> Void

    @State private var isGenerating = true
    @State private var draft: RecipeDraft?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                if isGenerating {
                    generatingView
                } else if errorMessage != nil {
                    errorView
                } else {
                    // Draft ready — review-sheet covers this view
                    // via .sheet below; just show a hand-off
                    // breadcrumb in case it's still mid-transition.
                    breadcrumbView
                }
            }
            .paperBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.large])
        .task {
            await generateRecipe()
        }
        .sheet(item: $draft) { initialDraft in
            RecipeDraftReviewSheet(
                initialDraft: initialDraft,
                refineContextHint: "a meal called \"\(mealName)\"",
                onSave: { saved in
                    Task {
                        await onSaved(saved)
                        dismiss()
                    }
                },
                onDiscard: {
                    // Discarded — close out the parent shell too.
                    dismiss()
                }
            )
        }
    }

    private var generatingView: some View {
        VStack(spacing: SMSpacing.xl) {
            ProgressView()
                .tint(SMColor.primary)
                .scaleEffect(1.5)

            VStack(spacing: SMSpacing.sm) {
                Text("Drafting recipe…")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                Text("AI is building a draft for \"\(mealName)\". You'll be able to refine or edit before saving.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(SMSpacing.xl)
    }

    private var errorView: some View {
        VStack(spacing: SMSpacing.lg) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(SMColor.destructive)
            if let errorMessage {
                Text(errorMessage)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Try Again") {
                Task { await generateRecipe() }
            }
            .foregroundStyle(SMColor.primary)
            Spacer()
        }
        .padding(SMSpacing.xl)
    }

    private var breadcrumbView: some View {
        Text("Draft ready — review opening…")
            .foregroundStyle(SMColor.textSecondary)
    }

    private func generateRecipe() async {
        isGenerating = true
        errorMessage = nil
        do {
            let aiDraft = try await appState.apiClient.generateRecipeSuggestionDraft(goal: mealName)
            draft = aiDraft.draft
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }
}

extension RecipeDraft: Identifiable {
    public var id: String { recipeId ?? name }
}
