import SimmerSmithKit
import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppState.self) private var appState

    let presentation: OnboardingPresentation
    @State private var draft: OnboardingDraft
    @State private var step = 1
    @State private var ingredientSearch = ""
    @State private var ingredientResults: [BaseIngredient] = []
    @State private var isSearching = false
    @State private var isCompleting = false
    @State private var errorMessage: String?
    @State private var ingredientSearchFailed = false
    @State private var ingredientMode: OnboardingIngredientMode = .avoid

    init(presentation: OnboardingPresentation) {
        self.presentation = presentation
        _draft = State(initialValue: presentation.draft)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.paper.ignoresSafeArea()
                PaperGrain().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: SMSpacing.xl) {
                        VStack(alignment: .leading, spacing: SMSpacing.xs) {
                            Text("Step \(step) of 4")
                                .font(SMFont.caption.weight(.semibold))
                                .foregroundStyle(SMColor.ember)
                            Text(stepTitle)
                                .font(SMFont.display)
                                .foregroundStyle(SMColor.textPrimary)
                            Text(stepSubtitle)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }

                        stepContent

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(SMFont.caption)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Error: \(errorMessage)")
                        }
                    }
                    .padding(SMSpacing.xxl)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            errorMessage = nil
                            step -= 1
                        }
                        .disabled(isCompleting)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    switch presentation.mode {
                    case .automatic:
                        Button("Skip for now") {
                            skipAutomaticOnboarding()
                        }
                        .disabled(isCompleting)
                    case .manual:
                        Button("Cancel") {
                            appState.cancelOnboarding()
                        }
                        .disabled(isCompleting)
                    }
                }

                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if step == 4 {
                            completeOnboarding()
                        } else {
                            errorMessage = nil
                            step += 1
                        }
                    } label: {
                        HStack(spacing: SMSpacing.sm) {
                            if isCompleting {
                                ProgressView()
                            }
                            Text(step == 4 ? "Done" : "Continue")
                        }
                    }
                    .disabled(isCompleting)
                    .accessibilityHint(step == 4
                        ? "Saves your meal planning setup."
                        : "Moves to the next setup step.")
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1:
            householdSizeStep
        case 2:
            ingredientPreferencesStep
        case 3:
            cuisinesStep
        default:
            planSetupStep
        }
    }

    private var householdSizeStep: some View {
        VStack(alignment: .leading, spacing: SMSpacing.lg) {
            Stepper("Household size: \(draft.householdSize) people", value: $draft.householdSize, in: 1...12)
                .font(SMFont.body)
                .accessibilityLabel("Household size")
                .accessibilityValue("\(draft.householdSize) people")

            Text("You can fine-tune serving sizes later for individual recipes.")
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
        }
    }

    private var ingredientPreferencesStep: some View {
        VStack(alignment: .leading, spacing: SMSpacing.lg) {
            Picker("Preference", selection: $ingredientMode) {
                Text("Avoid").tag(OnboardingIngredientMode.avoid)
                Text("Allergy").tag(OnboardingIngredientMode.allergy)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Ingredient preference")

            TextField("Search ingredients", text: $ingredientSearch)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .accessibilityHint("Search the ingredient catalog to add an avoid or allergy.")

            if isSearching {
                HStack(spacing: SMSpacing.sm) {
                    ProgressView()
                    Text("Searching ingredients")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else if ingredientSearchFailed {
                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                    Text("We couldn't load ingredients.")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                    Button("Retry") {
                        Task { await searchIngredients() }
                    }
                    .accessibilityHint("Retries the current ingredient search.")
                }
            } else if !ingredientSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ingredientResults.isEmpty {
                Text("No matching ingredients found.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
            } else {
                ForEach(ingredientResults) { ingredient in
                    Button {
                        addIngredient(ingredient)
                    } label: {
                        HStack {
                            Text(ingredient.name)
                                .foregroundStyle(SMColor.textPrimary)
                            Spacer()
                            Image(systemName: isIngredientSelected(ingredient)
                                ? "checkmark.circle.fill"
                                : "plus.circle")
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isIngredientSelected(ingredient))
                    .accessibilityLabel("Add \(ingredient.name)")
                    .accessibilityValue(isIngredientSelected(ingredient) ? "Added" : "Not added")
                    .accessibilityHint(isIngredientSelected(ingredient)
                        ? "Already added as \(ingredientMode.rawValue)."
                        : "Adds as \(ingredientMode.rawValue).")
                }
            }

            if !draft.ingredientChoices.isEmpty {
                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                    Text("Selected")
                        .font(SMFont.subheadline.weight(.semibold))
                        .foregroundStyle(SMColor.textPrimary)

                    ForEach(draft.ingredientChoices) { choice in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.baseIngredientName)
                                    .foregroundStyle(SMColor.textPrimary)
                                Text(choice.mode == .allergy ? "Allergy" : "Avoid")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                draft.ingredientChoices.removeAll {
                                    $0.id == choice.id
                                }
                            }
                            .accessibilityLabel("Remove \(choice.baseIngredientName) \(choice.mode.rawValue)")
                        }
                        .padding(.vertical, SMSpacing.xs)
                    }
                }
            }
        }
        .task(id: ingredientSearch) {
            await searchIngredients()
        }
    }

    private var cuisinesStep: some View {
        let cuisines = appState.recipeMetadata?.cuisines ?? []

        return VStack(alignment: .leading, spacing: SMSpacing.lg) {
            if cuisines.isEmpty {
                ContentUnavailableView {
                    Label("Cuisines unavailable", systemImage: "fork.knife")
                } description: {
                    Text("Try again when your recipe metadata is available.")
                } actions: {
                    Button("Retry") {
                        Task { await appState.refreshRecipeMetadata() }
                    }
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: SMSpacing.sm)],
                    alignment: .leading,
                    spacing: SMSpacing.sm
                ) {
                    ForEach(cuisines) { cuisine in
                        let selected = isCuisineSelected(cuisine.name)
                        Button {
                            toggleCuisine(cuisine.name)
                        } label: {
                            Label(cuisine.name, systemImage: selected ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? SMColor.ember : SMColor.textSecondary)
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var planSetupStep: some View {
        VStack(alignment: .leading, spacing: SMSpacing.lg) {
            Text("Your weekly plan covers Monday–Sunday.")
                .font(SMFont.body)
                .foregroundStyle(SMColor.textPrimary)

            LabeledContent("Timezone") {
                Text(draft.timeZoneIdentifier)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Setup summary")
                    .font(SMFont.subheadline.weight(.semibold))
                    .foregroundStyle(SMColor.textPrimary)
                LabeledContent("Household") {
                    Text("\(draft.householdSize) people")
                }
                LabeledContent("Constraints") {
                    Text("\(draft.ingredientChoices.count)")
                }
                LabeledContent("Cuisines") {
                    Text("\(draft.likedCuisines.count)")
                }
            }
            .foregroundStyle(SMColor.textSecondary)
        }
    }

    private var stepTitle: String {
        switch step {
        case 1: "Who are you planning for?"
        case 2: "Anything to avoid?"
        case 3: "What sounds good?"
        default: "Set up your week"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case 1: "Start with the number of people you usually cook for."
        case 2: "Add ingredients you avoid or allergies to keep meals on track."
        case 3: "Pick cuisines you would like to see more often."
        default: "Review your choices before you start planning meals."
        }
    }

    private func searchIngredients() async {
        let query = ingredientSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        ingredientSearchFailed = false
        errorMessage = nil
        defer { isSearching = false }

        do {
            let results = try await appState.searchBaseIngredients(query: query, limit: 20)
            guard !Task.isCancelled,
                  ingredientSearch.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            ingredientResults = results
        } catch {
            guard !Task.isCancelled else { return }
            ingredientResults = []
            errorMessage = error.localizedDescription
            ingredientSearchFailed = true
        }
    }

    private func addIngredient(_ ingredient: BaseIngredient) {
        guard !isIngredientSelected(ingredient) else { return }

        draft.ingredientChoices.append(OnboardingIngredientChoice(
            baseIngredientID: ingredient.baseIngredientId,
            baseIngredientName: ingredient.name,
            mode: ingredientMode
        ))
    }

    private func isIngredientSelected(_ ingredient: BaseIngredient) -> Bool {
        draft.ingredientChoices.contains {
            $0.baseIngredientID == ingredient.baseIngredientId && $0.mode == ingredientMode
        }
    }

    private func isCuisineSelected(_ cuisine: String) -> Bool {
        draft.likedCuisines.contains {
            $0.caseInsensitiveCompare(cuisine) == .orderedSame
        }
    }

    private func toggleCuisine(_ cuisine: String) {
        if isCuisineSelected(cuisine) {
            draft.likedCuisines.removeAll {
                $0.caseInsensitiveCompare(cuisine) == .orderedSame
            }
        } else {
            draft.likedCuisines.append(cuisine)
        }
    }

    private func skipAutomaticOnboarding() {
        do {
            try appState.dismissAutomaticOnboarding()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeOnboarding() {
        isCompleting = true
        errorMessage = nil
        do {
            try appState.completeOnboarding(draft)
        } catch {
            errorMessage = error.localizedDescription
            isCompleting = false
        }
    }
}
