import SimmerSmithKit
import SwiftUI
import UIKit

/// Full-screen, big-text cook flow. Phase 1 ships the skeleton: manual
/// advance via prev/next, long-press the step to launch the M11
/// `CookCheckSheet`, and a per-step "Ask assistant" hand-off that
/// dismisses cook mode and routes to the assistant tab with prefilled
/// step context. Wake-lock is held for the entire session so the
/// screen does not auto-lock while the user has hands in the pan.
struct CookingModeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let recipeID: String

    @State private var stepIndex = 0
    @State private var cookCheckContext: CookCheckSheetContext?
    @State private var errorMessage: String?

    var body: some View {
        let recipe = appState.recipes.first { $0.recipeId == recipeID }
        let steps = orderedSteps(for: recipe)

        ZStack {
            SMColor.surface.ignoresSafeArea()

            if let recipe, !steps.isEmpty {
                cookingBody(recipe: recipe, steps: steps)
            } else {
                emptyState
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(item: $cookCheckContext) { context in
            CookCheckSheet(context: context)
        }
    }

    // MARK: - Body

    private func cookingBody(recipe: RecipeSummary, steps: [RecipeStep]) -> some View {
        VStack(spacing: 0) {
            topBar(recipe: recipe, total: steps.count)
            Spacer(minLength: SMSpacing.lg)
            stepArea(recipe: recipe, steps: steps)
            Spacer(minLength: SMSpacing.lg)
            bottomBar(recipe: recipe, steps: steps)
        }
        .padding(.horizontal, SMSpacing.lg)
        .padding(.vertical, SMSpacing.lg)
    }

    // MARK: - Top bar

    private func topBar(recipe: RecipeSummary, total: Int) -> some View {
        HStack(spacing: SMSpacing.md) {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(recipe.name)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                    .lineLimit(1)
                Text("Step \(stepIndex + 1) of \(total)")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(SMColor.textSecondary)
            }
            .accessibilityLabel("Exit cooking mode")
        }
        .overlay(alignment: .bottom) {
            ProgressView(value: progressFraction(total: total))
                .tint(SMColor.primary)
                .padding(.top, SMSpacing.lg)
        }
        .padding(.bottom, SMSpacing.lg)
    }

    private func progressFraction(total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(stepIndex + 1) / Double(total)
    }

    // MARK: - Step area

    private func stepArea(recipe: RecipeSummary, steps: [RecipeStep]) -> some View {
        let step = steps[min(stepIndex, steps.count - 1)]
        return ScrollView {
            VStack(alignment: .leading, spacing: SMSpacing.lg) {
                Text(step.instruction)
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundStyle(SMColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onLongPressGesture {
                        cookCheckContext = CookCheckSheetContext(
                            recipeID: recipe.recipeId,
                            stepNumber: stepIndex,
                            stepText: step.instruction
                        )
                    }
                    .accessibilityHint("Long press to verify with a photo")

                if !step.substeps.isEmpty {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        ForEach(step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder })) { substep in
                            HStack(alignment: .top, spacing: SMSpacing.sm) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(SMColor.textTertiary)
                                    .padding(.top, 8)
                                Text(substep.instruction)
                                    .font(.system(size: 18))
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                        }
                    }
                    .padding(.top, SMSpacing.sm)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom bar

    private func bottomBar(recipe: RecipeSummary, steps: [RecipeStep]) -> some View {
        let isLastStep = stepIndex >= steps.count - 1
        let step = steps[min(stepIndex, steps.count - 1)]

        return VStack(spacing: SMSpacing.md) {
            Button {
                Task { await launchAssistant(recipe: recipe, step: step) }
            } label: {
                Label("Ask assistant", systemImage: "bubble.left.and.text.bubble.right")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.aiPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(SMColor.aiPurple.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: SMSpacing.md) {
                Button {
                    retreat()
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .font(SMFont.subheadline)
                        .foregroundStyle(stepIndex > 0 ? SMColor.textPrimary : SMColor.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .background(SMColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(stepIndex == 0)

                Button {
                    if isLastStep {
                        dismiss()
                    } else {
                        advance(total: steps.count)
                    }
                } label: {
                    Label(isLastStep ? "Done" : "Next",
                          systemImage: isLastStep ? "checkmark" : "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(SMFont.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .background(SMColor.primary)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "frying.pan")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.textTertiary)
            Text("No steps to cook")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text("Add steps to this recipe to use cooking mode.")
                .font(SMFont.body)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .foregroundStyle(SMColor.primary)
                .padding(.top, SMSpacing.md)
        }
        .padding(SMSpacing.xl)
    }

    // MARK: - Actions

    private func advance(total: Int) {
        guard stepIndex < total - 1 else { return }
        stepIndex += 1
    }

    private func retreat() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
    }

    private func launchAssistant(recipe: RecipeSummary, step: RecipeStep) async {
        let prefill = "I'm cooking \(recipe.name) and on step \(stepIndex + 1): \"\(step.instruction)\". "
        do {
            try await appState.beginAssistantLaunch(
                initialText: prefill,
                title: recipe.name,
                attachedRecipeID: recipe.recipeId,
                intent: "cooking_step_help"
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func orderedSteps(for recipe: RecipeSummary?) -> [RecipeStep] {
        recipe?.steps.sorted(by: { $0.sortOrder < $1.sortOrder }) ?? []
    }
}
