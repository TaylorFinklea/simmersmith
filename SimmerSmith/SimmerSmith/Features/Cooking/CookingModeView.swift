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
    @State private var voiceService = VoiceCommandService.shared
    @State private var isVoiceStopAlertPresented = false

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
            spokenService.activatePlaybackSession()
            speakCurrentStep(steps: steps)
        }
        .onChange(of: stepIndex) { _, _ in
            speakCurrentStep(steps: steps)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            spokenService.stop()
            voiceService.stop()
        }
        .sheet(item: $cookCheckContext) { context in
            CookCheckSheet(context: context)
        }
        .task {
            for await command in voiceService.commands {
                handleVoiceCommand(command, steps: steps)
            }
        }
        .alert("Stop cooking?", isPresented: $isVoiceStopAlertPresented) {
            Button("Stay", role: .cancel) {}
            Button("Stop", role: .destructive) { dismiss() }
        } message: {
            Text("Heard \"stop\". Exit cooking mode?")
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
                Task { await toggleVoiceCommands() }
            } label: {
                Image(systemName: voiceService.isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.title2)
                    .foregroundStyle(voiceService.isListening ? SMColor.success : SMColor.textTertiary)
            }
            .accessibilityLabel(voiceService.isListening ? "Stop voice commands" : "Start voice commands")

            Button {
                spokenService.isMuted.toggle()
            } label: {
                Image(systemName: spokenService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title2)
                    .foregroundStyle(spokenService.isMuted ? SMColor.textTertiary : SMColor.primary)
            }
            .accessibilityLabel(spokenService.isMuted ? "Unmute step readout" : "Mute step readout")

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

                if voiceService.isListening, let heard = voiceService.lastHeard, !heard.isEmpty {
                    Label(heard, systemImage: "waveform")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                        .lineLimit(2)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.sm)
                        .background(SMColor.surfaceCard)
                        .clipShape(Capsule())
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
                        onCompleted?()
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

    private func speakCurrentStep(steps: [RecipeStep]) {
        guard !steps.isEmpty else { return }
        let step = steps[min(stepIndex, steps.count - 1)]
        spokenService.speak(step.instruction)
    }

    private func toggleVoiceCommands() async {
        if voiceService.isListening {
            voiceService.stop()
            return
        }
        let granted = await voiceService.requestAuthorization()
        guard granted else {
            errorMessage = "Voice commands need microphone and speech-recognition permission. You can enable them in Settings."
            return
        }
        do {
            try voiceService.start()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleVoiceCommand(_ command: VoiceCommand, steps: [RecipeStep]) {
        switch command {
        case .next:
            advance(total: steps.count)
        case .previous:
            retreat()
        case .repeat:
            speakCurrentStep(steps: steps)
        case .stop:
            isVoiceStopAlertPresented = true
        }
    }
}
