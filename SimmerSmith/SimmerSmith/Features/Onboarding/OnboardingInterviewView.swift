import SwiftUI
import SimmerSmithKit

struct OnboardingInterviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    @State private var householdAdults = ""
    @State private var householdKids = ""
    @State private var dietaryConstraints = ""
    @State private var cuisinePreferences = ""
    @State private var cookingStyle = ""
    @State private var planningAvoids = ""
    @State private var isSaving = false

    private let totalSteps = 4

    var body: some View {
        ZStack {
            SMColor.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                ProgressView(value: Double(step + 1), total: Double(totalSteps + 1))
                    .tint(SMColor.primary)
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.top, SMSpacing.md)

                TabView(selection: $step) {
                    householdStep.tag(0)
                    dietStep.tag(1)
                    cuisineStep.tag(2)
                    styleStep.tag(3)
                    readyStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)
            }
        }
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if step > 0 {
                    Button { withAnimation { step -= 1 } } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Skip") {
                    Task { await finishOnboarding() }
                }
                .foregroundStyle(SMColor.textTertiary)
            }
        }
    }

    // MARK: - Steps

    private var householdStep: some View {
        interviewPage(
            icon: "person.2.fill",
            title: "Who's eating?",
            subtitle: "This helps AI plan the right portions."
        ) {
            VStack(spacing: SMSpacing.lg) {
                fieldRow(label: "Adults", placeholder: "2", text: $householdAdults, keyboard: .numberPad)
                fieldRow(label: "Kids", placeholder: "0", text: $householdKids, keyboard: .numberPad)
            }
        }
    }

    private var dietStep: some View {
        interviewPage(
            icon: "leaf.fill",
            title: "Any dietary needs?",
            subtitle: "Allergies, restrictions, or preferences."
        ) {
            VStack(spacing: SMSpacing.lg) {
                fieldRow(label: "Restrictions", placeholder: "e.g., gluten-free, nut allergy, vegetarian", text: $dietaryConstraints)
                fieldRow(label: "Avoids", placeholder: "e.g., mushrooms, cilantro, organ meats", text: $planningAvoids)
            }
        }
    }

    private var cuisineStep: some View {
        interviewPage(
            icon: "globe.americas.fill",
            title: "What cuisines do you love?",
            subtitle: "AI will lean toward these when planning."
        ) {
            fieldRow(label: "Favorites", placeholder: "e.g., Italian, Mexican, Thai, comfort food", text: $cuisinePreferences)
        }
    }

    private var styleStep: some View {
        interviewPage(
            icon: "timer",
            title: "How do you cook?",
            subtitle: "Quick weeknight meals? Weekend projects? Both?"
        ) {
            fieldRow(label: "Style", placeholder: "e.g., quick 30-min dinners, meal prep on Sundays, mix of easy and involved", text: $cookingStyle)
        }
    }

    private var readyStep: some View {
        VStack(spacing: SMSpacing.xl) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.primary)

            VStack(spacing: SMSpacing.sm) {
                Text("You're all set!")
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                Text("AI will use your preferences to plan personalized meals.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await finishOnboarding() }
            } label: {
                if isSaving {
                    ProgressView()
                        .tint(SMColor.surface)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                } else {
                    Text("Start Planning")
                        .font(SMFont.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                }
            }
            .foregroundStyle(.white)
            .background(SMColor.primary)
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            .disabled(isSaving)

            Spacer()
        }
        .padding(.horizontal, SMSpacing.xl)
    }

    // MARK: - Shared Components

    private func interviewPage<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: SMSpacing.xl) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(SMColor.primary)

            VStack(spacing: SMSpacing.sm) {
                Text(title)
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            content()

            Spacer()

            Button {
                withAnimation { step += 1 }
            } label: {
                Text("Continue")
                    .font(SMFont.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.lg)
            }
            .foregroundStyle(.white)
            .background(SMColor.primary)
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))

            Spacer()
                .frame(height: SMSpacing.xl)
        }
        .padding(.horizontal, SMSpacing.xl)
    }

    private func fieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Text(label)
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)

            TextField(placeholder, text: text, axis: .vertical)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textPrimary)
                .keyboardType(keyboard)
                .lineLimit(1...3)
                .padding(SMSpacing.md)
                .background(SMColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
        }
    }

    // MARK: - Save

    private func finishOnboarding() async {
        isSaving = true
        var settings: [String: String] = [:]
        if !householdAdults.isEmpty { settings["household_adults"] = householdAdults }
        if !householdKids.isEmpty { settings["household_kids"] = householdKids }
        if !dietaryConstraints.isEmpty { settings["dietary_constraints"] = dietaryConstraints }
        if !cuisinePreferences.isEmpty { settings["cuisine_preferences"] = cuisinePreferences }
        if !planningAvoids.isEmpty { settings["planning_avoids"] = planningAvoids }
        if !cookingStyle.isEmpty { settings["convenience_rules"] = cookingStyle }

        if !settings.isEmpty {
            _ = try? await appState.apiClient.updateProfile(settings: settings)
            await appState.refreshAll()
        }

        // Request notification permission
        _ = await NotificationManager.shared.requestPermission()

        dismiss()
    }
}
