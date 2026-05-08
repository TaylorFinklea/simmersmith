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
    var onCompleted: (() -> Void)?

    @State private var stepIndex = 0
    @State private var cookCheckContext: CookCheckSheetContext?
    @State private var errorMessage: String?
    @State private var spokenService = SpokenStepService.shared
    /// Build 67 — voice commands disabled (CoreAudio IPC + dispatch
    /// queue assert crash on iPhone 15 Pro). The mic icon stays as
    /// part of the visual composition; tapping it shows a
    /// "coming soon" alert instead of starting the engine.
    @State private var showingVoiceComingSoonAlert = false

    var body: some View {
        let recipe = appState.recipes.first { $0.recipeId == recipeID }
        let steps = orderedSteps(for: recipe)

        ZStack {
            // Build 58 — CookingMode is the Forge moment. Force the
            // forge palette regardless of system theme: lamp-lit iron
            // background with a soft ember glow seeping up from below.
            Color(hex: 0x15110D).ignoresSafeArea()
            RadialGradient(
                colors: [SMColor.ember.opacity(0.18), .clear],
                center: UnitPoint(x: 0.5, y: 1.1),
                startRadius: 0,
                endRadius: 600
            )
            .ignoresSafeArea()

            // Build 79 — hammered-iron grain. Static noise overlay
            // (deterministic seed) with a light ember tint so the
            // background reads as forged metal, not flat dark.
            HammeredGrain()
                .blendMode(.overlay)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if let recipe, !steps.isEmpty {
                cookingBody(recipe: recipe, steps: steps)
            } else {
                emptyState
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            spokenService.activatePlaybackSession()
            speakCurrentStep(steps: steps)
        }
        .onChange(of: stepIndex) { _, _ in
            speakCurrentStep(steps: steps)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            spokenService.stop()
        }
        .sheet(item: $cookCheckContext) { context in
            CookCheckSheet(context: context)
        }
        .alert("Voice commands coming soon", isPresented: $showingVoiceComingSoonAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hands-free \"next / back / stop\" is in the works. For now, tap the buttons below to advance steps.")
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

    /// Build 65 — Fusion Cooking top bar. Three columns:
    ///   ✕ close (left) | ◆ AT THE FORGE (center) | step counter (right)
    /// Mic + speaker controls move below the eyebrow row so the very
    /// top stays as quiet as the mockup. Progress hairline drawn
    /// underneath as a thin rule.
    private func topBar(recipe: RecipeSummary, total: Int) -> some View {
        VStack(spacing: SMSpacing.xs) {
            HStack(alignment: .center) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xEAE0CB))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Exit cooking mode")

                Spacer()

                Text("◆ AT THE FORGE")
                    .font(SMFont.monoLabel(10))
                    .tracking(2.4)
                    .foregroundStyle(SMColor.ember)

                Spacer()

                Text(String(format: "%02d/%02d", stepIndex + 1, total))
                    .font(SMFont.monoLabel(11))
                    .tracking(1.2)
                    .foregroundStyle(Color(hex: 0x8F8576))
            }

            // Quiet row of voice + mute toggles. Out of the way but
            // still one-tap reachable for hands-on cooking.
            // Build 67 — mic stays visually present but taps open a
            // "coming soon" alert; the underlying engine is disabled
            // pending a CoreAudio threading rework.
            HStack(spacing: SMSpacing.lg) {
                Spacer()
                Button {
                    showingVoiceComingSoonAlert = true
                } label: {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0x8F8576))
                }
                .accessibilityLabel("Voice commands (coming soon)")

                Button {
                    spokenService.isMuted.toggle()
                } label: {
                    Image(systemName: spokenService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(spokenService.isMuted ? Color(hex: 0x8F8576) : SMColor.ember)
                }
                .accessibilityLabel(spokenService.isMuted ? "Unmute step readout" : "Mute step readout")
            }
        }
        .padding(.bottom, SMSpacing.md)
        .overlay(alignment: .bottom) {
            // Ember progress seam — replaces the system ProgressView.
            // Reads as the hot-iron hairline from the mockup.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(hex: 0x33302A))
                        .frame(height: 1)
                    Rectangle()
                        .fill(SMColor.ember)
                        .frame(width: geo.size.width * progressFraction(total: total), height: 1.5)
                        .shadow(color: SMColor.ember.opacity(0.7), radius: 4)
                }
            }
            .frame(height: 1.5)
        }
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
                // Build 58 — Oswald stencil step number with ember glow.
                // The Forge takes over: this is the moment cooking
                // becomes a hot-iron event in the Smith's Notebook.
                Text(String(format: "%02d", stepIndex + 1))
                    .font(SMFont.stencil(96, bold: true))
                    .foregroundStyle(SMColor.ember)
                    .shadow(color: SMColor.ember.opacity(0.7), radius: 12)
                    .shadow(color: SMColor.ember.opacity(0.4), radius: 24)
                Text(step.instruction)
                    .font(SMFont.serifDisplay(26))
                    .foregroundStyle(Color(hex: 0xEAE0CB))
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

                CookingTimerChip()
                    .padding(.top, SMSpacing.sm)

                Button {
                    cookCheckContext = CookCheckSheetContext(
                        recipeID: recipe.recipeId,
                        stepNumber: stepIndex,
                        stepText: step.instruction
                    )
                } label: {
                    Label("Check it", systemImage: "viewfinder.circle")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.primary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.sm)
                        .background(SMColor.primary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Take a photo to check this step")

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

    /// Build 65 — Fusion Cooking bottom bar. Caveat ember `← prev`
    /// step indicator on the left, slightly-rotated ember `plate up →`
    /// CTA on the right (becomes "done →" on the last step). "Ask
    /// the smith" call moves into a small ember chip above the row,
    /// quiet enough to not compete with the next-step CTA.
    private func bottomBar(recipe: RecipeSummary, steps: [RecipeStep]) -> some View {
        let isLastStep = stepIndex >= steps.count - 1
        let step = steps[min(stepIndex, steps.count - 1)]
        let prevStepName = stepIndex > 0 ? "step \(stepIndex)" : nil
        let nextLabel = isLastStep ? "done →" : "next →"

        return VStack(spacing: SMSpacing.md) {
            Button {
                Task { await launchAssistant(recipe: recipe, step: step) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("ask the smith")
                        .font(SMFont.handwritten(15))
                }
                .foregroundStyle(SMColor.ember)
                .padding(.horizontal, SMSpacing.md)
                .padding(.vertical, 6)
                .overlay(
                    Capsule().stroke(SMColor.ember.opacity(0.5), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)

            HStack(alignment: .center) {
                Button {
                    retreat()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(prevStepName ?? "back")
                            .font(SMFont.handwritten(15))
                    }
                    .foregroundStyle(stepIndex > 0 ? Color(hex: 0x8F8576) : Color(hex: 0x6B6356))
                }
                .buttonStyle(.plain)
                .disabled(stepIndex == 0)

                Spacer()

                Button {
                    if isLastStep {
                        onCompleted?()
                        dismiss()
                    } else {
                        advance(total: steps.count)
                    }
                } label: {
                    Text(nextLabel)
                        .font(SMFont.handwritten(20, bold: true))
                        .foregroundStyle(Color(hex: 0x1A0E0A))
                        .padding(.horizontal, SMSpacing.lg)
                        .padding(.vertical, 12)
                        .background(SMColor.ember)
                        .shadow(color: SMColor.ember.opacity(0.6), radius: 14)
                        .rotationEffect(.degrees(-1))
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
        // Build 66 — dismiss the full-screen cooking cover *first* so
        // the user immediately sees the Smith tab open, then run the
        // network round-trip to create the assistant thread. The old
        // order made the button feel broken on slow networks because
        // the cover only dismissed after the await returned.
        let prefill = "I'm cooking \(recipe.name) and on step \(stepIndex + 1): \"\(step.instruction)\". "
        let recipeID = recipe.recipeId
        let title = recipe.name
        appState.selectedTab = .assistant
        dismiss()
        do {
            try await appState.beginAssistantLaunch(
                initialText: prefill,
                title: title,
                attachedRecipeID: recipeID,
                intent: "cooking_step_help"
            )
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func orderedSteps(for recipe: RecipeSummary?) -> [RecipeStep] {
        recipe?.steps.sorted(by: { $0.sortOrder < $1.sortOrder }) ?? []
    }

    private func speakCurrentStep(steps: [RecipeStep]) {
        guard !steps.isEmpty else { return }
        let step = steps[min(stepIndex, steps.count - 1)]
        spokenService.speak(step.instruction)
    }

}
