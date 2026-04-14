import SwiftUI
import SimmerSmithKit

struct AIRecipeCreateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let mealName: String
    let onSaved: (RecipeSummary) async -> Void

    @State private var isGenerating = false
    @State private var draft: RecipeDraft?
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                if isGenerating {
                    generatingView
                } else if let draft {
                    draftPreview(draft)
                } else {
                    promptView
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
        .task {
            await generateRecipe()
        }
    }

    // MARK: - States

    private var generatingView: some View {
        VStack(spacing: SMSpacing.xl) {
            ProgressView()
                .tint(SMColor.primary)
                .scaleEffect(1.5)

            VStack(spacing: SMSpacing.sm) {
                Text("Creating recipe...")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                Text("AI is building a recipe for \"\(mealName)\"")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(SMSpacing.xl)
    }

    private var promptView: some View {
        VStack(spacing: SMSpacing.xl) {
            Spacer()

            if let error = errorMessage {
                VStack(spacing: SMSpacing.lg) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(SMColor.destructive)

                    Text(error)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textSecondary)
                        .multilineTextAlignment(.center)

                    Button("Try Again") {
                        Task { await generateRecipe() }
                    }
                    .foregroundStyle(SMColor.primary)
                }
            }

            Spacer()
        }
        .padding(SMSpacing.xl)
    }

    private func draftPreview(_ recipeDraft: RecipeDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SMSpacing.lg) {
                Text(recipeDraft.name)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                HStack(spacing: SMSpacing.md) {
                    if !recipeDraft.cuisine.isEmpty {
                        CuisinePill(text: recipeDraft.cuisine)
                    }
                    if let prep = recipeDraft.prepMinutes, prep > 0 {
                        TimeBadge(minutes: prep)
                    }
                }

                if !recipeDraft.ingredients.isEmpty {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        Text("Ingredients")
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)

                        ForEach(recipeDraft.ingredients) { ingredient in
                            Text("• \(ingredient.ingredientName)")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textPrimary)
                        }
                    }
                }

                if !recipeDraft.steps.isEmpty {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        Text("Steps")
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)

                        ForEach(Array(recipeDraft.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: SMSpacing.sm) {
                                Text("\(index + 1).")
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.primary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(step.instruction)
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.textPrimary)
                            }
                        }
                    }
                }

                Button {
                    Task { await saveRecipe(recipeDraft) }
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(SMColor.surface)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                    } else {
                        Text("Save Recipe & Link to Meal")
                            .font(SMFont.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                    }
                }
                .foregroundStyle(.white)
                .background(SMColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                .disabled(isSaving)
                .padding(.top, SMSpacing.lg)
            }
            .padding(SMSpacing.xl)
        }
    }

    // MARK: - Actions

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

    private func saveRecipe(_ recipeDraft: RecipeDraft) async {
        isSaving = true

        do {
            let saved = try await appState.saveRecipe(recipeDraft)
            await onSaved(saved)
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
