import SwiftUI
import SimmerSmithKit

struct RecipeDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator
    @Environment(\.dismiss) private var dismiss

    let recipeID: String

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var assignmentContext: RecipeAssignmentSheetContext?
    @State private var companionContext: RecipeCompanionSheetContext?
    @State private var nutritionMatchContext: RecipeNutritionMatchContext?
    @State private var substitutionContext: SubstitutionSheetContext?
    @State private var cookCheckContext: CookCheckSheetContext?
    // Transient toast shown after marking an ingredient avoid/allergy —
    // clears itself after ~2s via a Task.sleep.
    @State private var preferenceToast: String?
    @State private var pendingDelete = false
    @State private var selectedScale: RecipeScaleOption = .single
    @State private var isGeneratingVariation = false
    @State private var isGeneratingCompanions = false
    @State private var showingSteps: Bool = false
    @State private var isCookingModePresented: Bool = false
    @State private var isRegeneratingImage = false
    @State private var isOverridingImage = false
    @State private var imageRemovalPending = false
    @State private var imageActionToast: String?
    /// M29 build 55 — variation/companion drafts route through the
    /// review sheet (refine loop + edit-by-hand + save) instead of
    /// straight to `RecipeEditorView`.
    @State private var pendingReviewDraft: PendingReviewDraft? = nil
    /// Build 66 — nutrition moves into a sheet behind a tappable
    /// calorie pill so it doesn't take up the bottom of every recipe.
    @State private var showingNutritionSheet = false

    private struct PendingReviewDraft: Identifiable {
        let id = UUID()
        let draft: RecipeDraft
        let contextHint: String
    }

    var body: some View {
        Group {
            if let recipe {
                ScrollView {
                    VStack(spacing: 0) {
                        headerSection(recipe)
                        contentSections(recipe)
                    }
                }
                .paperBackground()
                .scrollContentBackground(.hidden)
            } else if isLoading {
                ZStack {
                    Color.clear
                    ProgressView("Loading recipe...")
                        .tint(SMColor.ember)
                        .foregroundStyle(SMColor.inkSoft)
                }
                .paperBackground()
            } else {
                ZStack {
                    Color.clear
                    VStack(spacing: SMSpacing.lg) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 48))
                            .foregroundStyle(SMColor.inkFaint)
                        Text("Recipe Unavailable")
                            .font(SMFont.serifDisplay(22))
                            .foregroundStyle(SMColor.ink)
                        Text(errorMessage ?? "The recipe could not be loaded.")
                            .font(SMFont.bodySerif(15))
                            .foregroundStyle(SMColor.inkSoft)
                            .multilineTextAlignment(.center)
                    }
                    .padding(SMSpacing.xl)
                }
                .paperBackground()
            }
        }
        .navigationTitle(recipe?.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { publishContext() }
        .onChange(of: recipe?.recipeId) { _, _ in publishContext() }
        .overlay(alignment: .top) {
            if let toast = preferenceToast {
                Text(toast)
                    .font(SMFont.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, SMSpacing.md)
                    .padding(.vertical, SMSpacing.sm)
                    .background(SMColor.primary.opacity(0.92), in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, SMSpacing.lg)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: preferenceToast)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let recipe {
                    HStack(spacing: SMSpacing.lg) {
                        Button {
                            Task { await toggleFavorite(recipe) }
                        } label: {
                            Image(systemName: recipe.favorite ? "heart.fill" : "heart")
                                .foregroundStyle(recipe.favorite ? SMColor.favoritePink : SMColor.textSecondary)
                        }

                        Button {
                            isCookingModePresented = true
                        } label: {
                            Image(systemName: "frying.pan")
                                .foregroundStyle(SMColor.primary)
                        }
                        .accessibilityLabel("Start cooking mode")
                        .disabled(recipe.steps.isEmpty)

                        Menu {
                            Button {
                                editorContext = RecipeEditorSheetContext(title: "Edit Recipe", draft: recipe.editingDraft())
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button {
                                editorContext = RecipeEditorSheetContext(title: "New Variation", draft: recipe.variationDraft())
                            } label: {
                                Label("Create Variation", systemImage: "square.on.square")
                            }
                            Menu("AI Variation Draft") {
                                ForEach(RecipeVariationGoal.allCases) { goal in
                                    Button(goal.title) {
                                        Task { await generateVariation(recipe, goal: goal) }
                                    }
                                    .disabled(isGeneratingVariation)
                                }
                            }
                            Button {
                                Task { await generateCompanions(recipe) }
                            } label: {
                                Label("AI Companion Suggestions", systemImage: "sparkles")
                            }
                            .disabled(isGeneratingCompanions)
                            Button {
                                Task {
                                    do {
                                        try await appState.beginAssistantLaunch(
                                            initialText: "Help me with this recipe. Suggest improvements, substitutions, or troubleshooting advice.",
                                            title: recipe.name,
                                            attachedRecipeID: recipe.recipeId,
                                            intent: "cooking_help"
                                        )
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("Ask Assistant", systemImage: "bubble.left.and.text.bubble.right")
                            }
                            Button {
                                assignmentContext = RecipeAssignmentSheetContext(recipes: [recipe])
                            } label: {
                                Label("Add to Week", systemImage: "calendar.badge.plus")
                            }
                            ShareLink(
                                item: formatRecipeForSharing(recipe),
                                subject: Text(recipe.name),
                                message: Text("Check out this recipe!")
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Divider()
                            Button {
                                Task { await regenerateImage(recipe) }
                            } label: {
                                Label("Regenerate image", systemImage: "sparkles")
                            }
                            .disabled(isRegeneratingImage)
                            Button {
                                isOverridingImage = true
                            } label: {
                                Label("Use my own photo", systemImage: "photo.on.rectangle.angled")
                            }
                            if recipe.imageUrl != nil {
                                Button(role: .destructive) {
                                    imageRemovalPending = true
                                } label: {
                                    Label("Remove image", systemImage: "trash")
                                }
                            }
                            Divider()
                            if recipe.archived {
                                Button {
                                    Task { await restore(recipe) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                            } else {
                                Button {
                                    Task { await archive(recipe) }
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }
                            Button(role: .destructive) {
                                pendingDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }
            }
        }
        .smithToolbar()
        .task(id: recipeID) {
            await loadRecipe()
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .sheet(item: $assignmentContext) { context in
            RecipeWeekAssignmentView(recipes: context.recipes)
        }
        .sheet(item: $companionContext) { context in
            RecipeCompanionOptionsView(context: context) { selected in
                // M29 build 55 — companion drafts route through
                // the review sheet for refine + edit before save.
                companionContext = nil
                pendingReviewDraft = PendingReviewDraft(
                    draft: selected.draft,
                    contextHint: "a \(selected.label.lowercased()) companion for \"\(recipe?.name ?? "this dish")\""
                )
            }
        }
        .sheet(item: $pendingReviewDraft) { pending in
            RecipeDraftReviewSheet(
                initialDraft: pending.draft,
                refineContextHint: pending.contextHint,
                onSave: { _ in /* recipe upserts into appState.recipes */ }
            )
        }
        .sheet(item: $nutritionMatchContext) { context in
            RecipeNutritionMatchView(context: context) {
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .sheet(item: $substitutionContext) { context in
            SubstitutionSheetView(
                recipe: context.recipe,
                ingredient: context.ingredient,
                onApplied: {
                    Task { await loadRecipe(forceRefresh: true) }
                },
                onVariationCreated: { _ in
                    // Refresh the library so the new variation shows up.
                    // The user stays on the original recipe — the
                    // variation is reachable from the Recipes list.
                    Task { await appState.refreshRecipes() }
                }
            )
        }
        .sheet(item: $cookCheckContext) { context in
            CookCheckSheet(context: context)
        }
        .sheet(isPresented: $showingNutritionSheet) {
            if let recipe, let nutrition = recipe.nutritionSummary {
                NavigationStack {
                    ScrollView {
                        nutritionSection(recipe, nutritionSummary: nutrition)
                            .padding(.horizontal, SMSpacing.lg)
                            .padding(.vertical, SMSpacing.lg)
                    }
                    .paperBackground()
                    .scrollContentBackground(.hidden)
                    .navigationTitle("Nutrition")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingNutritionSheet = false }
                                .foregroundStyle(SMColor.ember)
                        }
                    }
                    .smithToolbar()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: $isCookingModePresented) {
            CookingModeView(recipeID: recipeID, onCompleted: showCookingCompletionToast)
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let recipe {
                    Task { await delete(recipe) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recipe from the library. Existing week meals keep their copied names and ingredients.")
        }
        .sheet(isPresented: $isOverridingImage) {
            RecipeImageOverrideSheet(recipeID: recipeID)
        }
        .confirmationDialog(
            "Remove this recipe's image?",
            isPresented: $imageRemovalPending,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await removeImage() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recipe will fall back to a gradient placeholder until you regenerate or upload a new photo.")
        }
        .alert("Image", isPresented: Binding(
            get: { imageActionToast != nil },
            set: { if !$0 { imageActionToast = nil } }
        ), presenting: imageActionToast) { _ in
            Button("OK", role: .cancel) { imageActionToast = nil }
        } message: { toast in
            Text(toast)
        }
    }

    // MARK: - Header Section

    /// Build 64 — Fusion RecipeDetail header. Replaces the dark
    /// image-with-overlaid-title slab with a centered notebook
    /// composition: mono eyebrow → italic-serif title → Caveat
    /// sub-line → circular hero image with an ember-dot annotation
    /// → dashed stat row (3 numerals).
    private func headerSection(_ recipe: RecipeSummary) -> some View {
        VStack(alignment: .center, spacing: SMSpacing.md) {
            FuEyebrow(text: recipe.archived ? "archived recipe" : "recipe")
                .padding(.top, SMSpacing.lg)

            Text(recipe.name)
                .font(SMFont.serifDisplay(38))
                .foregroundStyle(SMColor.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, SMSpacing.lg)

            if !recipe.subtitleFragments.isEmpty {
                Text(recipe.subtitleFragments.map { $0.lowercased() }.joined(separator: " · "))
                    .font(SMFont.handwritten(16))
                    .foregroundStyle(SMColor.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SMSpacing.lg)
            }

            // Circular hero with ember-dot annotation. The dot's
            // shadow-glow is what gives the "smith's mark" feel
            // without needing a custom illustration.
            ZStack(alignment: .topTrailing) {
                RecipeHeaderImage(recipe: recipe, isLoading: isRegeneratingImage)
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(SMColor.ink, lineWidth: 1.5)
                    )

                Circle()
                    .fill(SMColor.ember)
                    .frame(width: 14, height: 14)
                    .shadow(color: SMColor.ember.opacity(0.55), radius: 6)
                    .offset(x: -18, y: 4)
            }
            .padding(.vertical, SMSpacing.sm)

            recipeStatRow(recipe)
                .padding(.horizontal, SMSpacing.lg)
        }
        .frame(maxWidth: .infinity)
    }

    /// Build 64 — three big numerals in italic-serif with Caveat
    /// unit labels, framed top + bottom by dashed hairlines. Picks
    /// the most useful numbers (total time / servings / ingredient
    /// count) and falls back to "—" when a value is missing.
    private func recipeStatRow(_ recipe: RecipeSummary) -> some View {
        let totalMinutes = (recipe.prepMinutes ?? 0) + (recipe.cookMinutes ?? 0)
        let stats: [(value: String, label: String)] = [
            (totalMinutes > 0 ? "\(totalMinutes)" : "—", "minutes"),
            (recipe.servings.map { "\(Int($0))" } ?? "—", "plates"),
            ("\(recipe.ingredients.count)",
             recipe.ingredients.count == 1 ? "ingredient" : "ingredients"),
        ]

        return VStack(spacing: 0) {
            DashedRule()
            HStack(spacing: 0) {
                ForEach(stats, id: \.label) { stat in
                    VStack(spacing: 2) {
                        Text(stat.value)
                            .font(SMFont.serifDisplay(26))
                            .foregroundStyle(SMColor.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(stat.label)
                            .font(SMFont.handwritten(14))
                            .foregroundStyle(SMColor.inkSoft)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 12)
            DashedRule()
        }
    }

    // MARK: - Content Sections

    private func contentSections(_ recipe: RecipeSummary) -> some View {
        VStack(spacing: SMSpacing.lg) {
            // AI progress indicators
            if isGeneratingVariation {
                aiProgressCard(text: "Generating AI variation draft...")
            }

            if isGeneratingCompanions {
                aiProgressCard(text: "Generating companion suggestions...")
            }

            // Metadata pills (wrapping)
            metadataPills(recipe)

            // Tags
            if !recipe.tags.isEmpty {
                tagSection(recipe)
            }

            // Scale picker
            scaleSection

            // Variations
            if !variantRecipes(for: recipe).isEmpty {
                variationsSection(recipe)
            }

            // Ingredients / Steps toggle
            if !recipe.ingredients.isEmpty || !recipe.steps.isEmpty || !recipe.instructionsSummary.isEmpty {
                ingredientsStepsPicker

                if showingSteps {
                    if !recipe.steps.isEmpty {
                        stepsSection(recipe)
                    } else if !recipe.instructionsSummary.isEmpty {
                        instructionsSummarySection(recipe)
                    } else {
                        SMCard {
                            Text("No steps have been added yet.")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                } else {
                    if !recipe.ingredients.isEmpty {
                        ingredientsSection(recipe)
                    } else {
                        SMCard {
                            Text("No ingredients have been added yet.")
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }
                }
            }

            // Pairings (M12)
            RecipePairingsCard(recipeID: recipe.recipeId)

            // Notes
            if !recipe.notes.isEmpty {
                notesSection(title: "Notes", text: recipe.notes, icon: "note.text")
            }

            // Memories — live log of cooks (M15)
            RecipeMemoriesSection(recipeID: recipe.recipeId)

            // Source
            if !recipe.sourceLabel.isEmpty || !recipe.sourceUrl.isEmpty || recipe.sourceRecipeCount > 0 {
                sourceSection(recipe)
            }

            // Error
            if let errorMessage {
                SMCard {
                    Text(errorMessage)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.destructive)
                }
            }
        }
        .padding(.horizontal, SMSpacing.lg)
        .padding(.top, SMSpacing.lg)
        .padding(.bottom, SMSpacing.xxl)
    }

    // MARK: - Metadata Pills

    private func metadataPills(_ recipe: RecipeSummary) -> some View {
        // Build 66 — calorie pill back at the top, tappable to open
        // the full nutrition modal (sheet). Other softer-tail
        // metadata stays inline; the full breakdown is no longer
        // taking up real estate at the bottom of every recipe.
        WrappingHStack(spacing: SMSpacing.sm) {
            if let calorieText = calorieChipText(for: recipe) {
                Button {
                    showingNutritionSheet = true
                } label: {
                    metadataPill(icon: "flame", text: calorieText)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open nutrition details")
            }

            metadataPill(icon: "clock.arrow.circlepath", text: recipe.usageSummary)

            if !recipe.overrideFields.isEmpty {
                metadataPill(icon: "slider.horizontal.3", text: recipe.overrideFields.joined(separator: ", "))
            }
            if let score = recipe.difficultyScore {
                metadataPill(icon: "chart.bar", text: difficultyLabel(score))
            }
            if recipe.kidFriendly {
                metadataPill(icon: "face.smiling", text: "Kid-friendly")
            }
        }
    }

    private func difficultyLabel(_ score: Int) -> String {
        switch score {
        case ...2: return "Easy"
        case 3: return "Medium"
        default: return "Hard"
        }
    }

    private func calorieChipText(for recipe: RecipeSummary) -> String? {
        guard let nutrition = recipe.nutritionSummary else { return nil }
        let hasUnmatched = nutrition.unmatchedIngredientCount > 0
        if let cps = nutrition.caloriesPerServing {
            let value = Int(cps.rounded())
            return hasUnmatched ? "~\(value) cal (estimate)" : "\(value) cal"
        }
        if let total = nutrition.totalCalories {
            let value = Int(total.rounded())
            return hasUnmatched ? "~\(value) cal (estimate)" : "\(value) cal"
        }
        return nil
    }

    /// Build 64 — Fusion outlined pill. Caveat label, ember icon
    /// when applicable, no fill — sits on paper as a margin tag.
    private func metadataPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(SMColor.ember)
            Text(text.lowercased())
                .font(SMFont.handwritten(13))
                .foregroundStyle(SMColor.inkSoft)
        }
        .padding(.horizontal, SMSpacing.md)
        .padding(.vertical, 4)
        .overlay(
            Capsule().stroke(SMColor.rule, lineWidth: 0.8)
        )
    }

    // MARK: - Ingredients / Steps Picker

    private var ingredientsStepsPicker: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingSteps = false
                }
            } label: {
                Text("Ingredients")
                    .font(SMFont.label)
                    .foregroundStyle(!showingSteps ? SMColor.primary : SMColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(!showingSteps ? SMColor.primary.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingSteps = true
                }
            } label: {
                Text("Steps")
                    .font(SMFont.label)
                    .foregroundStyle(showingSteps ? SMColor.primary : SMColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.md)
                    .background(showingSteps ? SMColor.primary.opacity(0.15) : Color.clear)
            }
            .buttonStyle(.plain)
        }
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
    }

    // MARK: - Tags

    private func tagSection(_ recipe: RecipeSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(recipe.tags, id: \.self) { tag in
                    Text(tag)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                        .padding(.horizontal, SMSpacing.md)
                        .padding(.vertical, SMSpacing.xs)
                        .background(SMColor.primary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - Scale

    private var scaleSection: some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Scale")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                HStack(spacing: SMSpacing.sm) {
                    ForEach(RecipeScaleOption.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedScale = option
                            }
                        } label: {
                            Text(option.title)
                                .font(SMFont.label)
                                .foregroundStyle(selectedScale == option ? .white : SMColor.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SMSpacing.sm)
                                .background(selectedScale == option ? SMColor.primary : SMColor.surface)
                                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Nutrition

    private func nutritionSection(_ recipe: RecipeSummary, nutritionSummary: NutritionSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Calories")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                if let caloriesPerServing = nutritionSummary.caloriesPerServing {
                    Text("\(Int(caloriesPerServing.rounded())) calories per serving")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)
                } else if let totalCalories = nutritionSummary.totalCalories {
                    Text("\(Int(totalCalories.rounded())) calories total")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)
                } else {
                    Text("No calorie estimate yet")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textSecondary)
                }

                HStack(spacing: SMSpacing.md) {
                    Text(nutritionSummary.statusLabel)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                    Text("\(nutritionSummary.matchedIngredientCount) matched")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.success)
                    if nutritionSummary.unmatchedIngredientCount > 0 {
                        Text("\(nutritionSummary.unmatchedIngredientCount) unmatched")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.accent)
                    }
                }

                if !nutritionSummary.unmatchedIngredients.isEmpty {
                    Divider()
                        .background(SMColor.divider)

                    ForEach(nutritionSummary.unmatchedIngredients, id: \.self) { ingredient in
                        Button {
                            let normalizedName = recipe.ingredients.first {
                                $0.ingredientName.localizedCaseInsensitiveCompare(ingredient) == .orderedSame
                            }?.normalizedName
                            nutritionMatchContext = RecipeNutritionMatchContext(
                                ingredientName: ingredient,
                                normalizedName: normalizedName
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ingredient)
                                        .font(SMFont.body)
                                        .foregroundStyle(SMColor.textPrimary)
                                    Text("Match nutrition to improve this estimate")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Variations

    private func variationsSection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Variations")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                ForEach(variantRecipes(for: recipe)) { variant in
                    NavigationLink {
                        RecipeDetailView(recipeID: variant.recipeId)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                                Text(variant.name)
                                    .font(SMFont.subheadline)
                                    .foregroundStyle(SMColor.textPrimary)
                                Text(variant.usageSummary)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Ingredients

    /// Build 64 — Fusion ingredients list. Caveat ember "ingredients"
    /// header with hand underline + mono "X IN PANTRY" right eyebrow.
    /// Each row gets a HandCheck filled when the ingredient is in
    /// the user's pantry; HandRules between rows replace solid
    /// dividers. The per-ingredient "wand.and.stars" Menu (substitute
    /// / avoid / allergy) is kept exactly as-is — pure functionality.
    private func ingredientsSection(_ recipe: RecipeSummary) -> some View {
        let scaled = recipe.ingredients.map { $0.scaled(by: selectedScale.rawValue) }
        let inPantryCount = scaled.filter { isInPantry($0) }.count

        return VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: SMSpacing.sm) {
                    Text("ingredients")
                        .font(SMFont.handwritten(20, bold: true))
                        .foregroundStyle(SMColor.ember)
                    HandUnderline(color: SMColor.ember, width: 32)
                }
                Spacer()
                if inPantryCount > 0 {
                    Text("\(inPantryCount) in pantry")
                        .font(SMFont.monoLabel(9))
                        .tracking(1.2)
                        .foregroundStyle(SMColor.inkSoft)
                }
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.top, SMSpacing.sm)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scaled.enumerated()), id: \.element.id) { idx, ingredient in
                    let pantry = isInPantry(ingredient)
                    HStack(alignment: .top, spacing: SMSpacing.md) {
                        HandCheck(checked: pantry, size: 16)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(ingredient.ingredientName)
                                .font(SMFont.bodySerif(15))
                                .foregroundStyle(SMColor.ink)
                            if !ingredient.prep.isEmpty {
                                Text(ingredient.prep)
                                    .font(SMFont.bodySerifItalic(13))
                                    .foregroundStyle(SMColor.inkSoft)
                            }
                        }

                        Spacer()

                        // Quantity + unit on the right, italic-serif numeral + Caveat unit.
                        HStack(spacing: 4) {
                            if let quantity = ingredient.quantity {
                                Text(quantity.formatted())
                                    .font(SMFont.serifDisplay(15))
                                    .foregroundStyle(SMColor.inkSoft)
                            }
                            if !ingredient.unit.isEmpty {
                                Text(ingredient.unit)
                                    .font(SMFont.handwritten(14))
                                    .foregroundStyle(SMColor.inkSoft)
                            }
                        }

                        // Per-ingredient AI menu: substitute, avoid,
                        // allergy. Functionality identical, ember tint.
                        Menu {
                            Button {
                                substitutionContext = SubstitutionSheetContext(
                                    recipe: recipe,
                                    ingredient: ingredient
                                )
                            } label: {
                                Label("Substitute…", systemImage: "arrow.triangle.2.circlepath")
                            }

                            if let baseID = ingredient.baseIngredientId, !baseID.isEmpty {
                                Divider()
                                Button {
                                    Task { await markPreference(ingredient: ingredient, mode: "avoid") }
                                } label: {
                                    Label("Never use this in my plans", systemImage: "nosign")
                                }
                                Button(role: .destructive) {
                                    Task { await markPreference(ingredient: ingredient, mode: "allergy") }
                                } label: {
                                    Label("I'm allergic to this", systemImage: "exclamationmark.triangle")
                                }
                            }
                        } label: {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(SMColor.ember.opacity(0.85))
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("Options for \(ingredient.ingredientName)")
                    }
                    .padding(.vertical, 8)

                    if idx < scaled.count - 1 {
                        HandRule(color: SMColor.rule, height: 4, lineWidth: 0.7)
                    }
                }
            }
            .padding(.horizontal, SMSpacing.lg)
        }
    }

    /// Build 64 — best-effort "is this ingredient in the user's
    /// pantry?" check. PantryItem doesn't carry a base-ingredient
    /// ID; we use case-insensitive name comparison against the
    /// pre-normalized pantry name. Not perfect for "milk" vs "whole
    /// milk" but good enough as a hint while we build a real catalog
    /// matcher server-side.
    private func isInPantry(_ ingredient: RecipeIngredient) -> Bool {
        let needle = ingredient.ingredientName.lowercased()
        guard !needle.isEmpty else { return false }
        return appState.pantryItems.contains { item in
            let hay = item.normalizedName.isEmpty
                ? item.stapleName.lowercased()
                : item.normalizedName.lowercased()
            return hay == needle || hay.contains(needle) || needle.contains(hay)
        }
    }

    // MARK: - Steps

    private func stepsSection(_ recipe: RecipeSummary) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            Text("Steps")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
                .padding(.leading, SMSpacing.xs)

            ForEach(recipe.steps.sorted(by: { $0.sortOrder < $1.sortOrder })) { step in
                SMCard {
                    VStack(alignment: .leading, spacing: SMSpacing.sm) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(step.sortOrder)")
                                .font(SMFont.headline)
                                .foregroundStyle(SMColor.primary)
                            Spacer()
                            Button {
                                cookCheckContext = CookCheckSheetContext(
                                    recipeID: recipe.recipeId,
                                    stepNumber: max(step.sortOrder - 1, 0),
                                    stepText: step.instruction
                                )
                            } label: {
                                Label("Check it", systemImage: "viewfinder.circle")
                                    .labelStyle(.iconOnly)
                                    .font(.title3)
                                    .foregroundStyle(SMColor.primary)
                            }
                            .accessibilityLabel("Take a photo to check this step")
                        }

                        Text(step.instruction)
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textPrimary)

                        if !step.substeps.isEmpty {
                            ForEach(step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder })) { substep in
                                HStack(alignment: .top, spacing: SMSpacing.sm) {
                                    Text("\(substepMarker(for: substep.sortOrder)).")
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                    Text(substep.instruction)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                                .padding(.leading, SMSpacing.md)
                            }
                        }
                    }
                }
            }

            Button {
                isCookingModePresented = true
            } label: {
                Label("Start cooking", systemImage: "frying.pan")
                    .font(SMFont.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SMSpacing.lg)
                    .background(SMColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, SMSpacing.sm)
        }
    }

    // MARK: - Instructions Summary

    private func instructionsSummarySection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Instructions")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                Text(recipe.instructionsSummary)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
            }
        }
    }

    // MARK: - Notes / Memories

    private func notesSection(title: String, text: String, icon: String) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Label(title, systemImage: icon)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                Text(text)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
            }
        }
    }

    // MARK: - Source

    private func sourceSection(_ recipe: RecipeSummary) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("Source")
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)

                if !recipe.sourceLabel.isEmpty {
                    Text(recipe.sourceLabel)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textPrimary)
                }

                if recipe.sourceRecipeCount > 0 {
                    Text("\(recipe.sourceRecipeCount) recipes from this source")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }

                if let url = URL(string: recipe.sourceUrl), !recipe.sourceUrl.isEmpty {
                    Link(destination: url) {
                        Label("Open original recipe", systemImage: "safari")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.primary)
                    }
                }
            }
        }
    }

    // MARK: - AI Progress Card

    private func aiProgressCard(text: String) -> some View {
        HStack(spacing: SMSpacing.md) {
            ProgressView()
                .tint(SMColor.aiPurple)
            Text(text)
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SMSpacing.lg)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    // MARK: - Helpers

    private func recipeHeaderGradient(for recipe: RecipeSummary) -> LinearGradient {
        let hash = abs(recipe.recipeId.hashValue)
        return SMColor.recipeGradients[hash % SMColor.recipeGradients.count]
    }

    private var recipe: RecipeSummary? {
        appState.recipes.first { $0.recipeId == recipeID }
    }

    private func ingredientLine(for ingredient: RecipeIngredient) -> String {
        [
            ingredient.quantity.map { $0.formatted() },
            ingredient.unit.isEmpty ? nil : ingredient.unit,
            ingredient.prep.isEmpty ? nil : ingredient.prep,
            ingredient.category.isEmpty ? nil : ingredient.category,
        ]
        .compactMap { $0 }
        .joined(separator: " \u{2022} ")
    }

    private func variantRecipes(for recipe: RecipeSummary) -> [RecipeSummary] {
        let rootID = recipe.baseRecipeId ?? recipe.recipeId
        return appState.recipes
            .filter { $0.baseRecipeId == rootID && $0.recipeId != recipe.recipeId && !$0.archived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func substepMarker(for index: Int) -> String {
        let base = UnicodeScalar(UInt32(96 + max(index, 1))) ?? UnicodeScalar(97)!
        return String(Character(base))
    }

    private func loadRecipe(forceRefresh: Bool = false) async {
        if !forceRefresh, recipe != nil {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await appState.fetchRecipe(recipeID: recipeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ recipe: RecipeSummary) async {
        do {
            try await appState.archiveRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishContext() {
        guard let recipe else {
            aiCoordinator.updateContext(
                AIPageContext(pageType: "recipe_detail", pageLabel: "Recipe")
            )
            return
        }
        aiCoordinator.updateContext(
            AIPageContext(
                pageType: "recipe_detail",
                pageLabel: recipe.name,
                recipeId: recipe.recipeId,
                recipeName: recipe.name,
                briefSummary: recipeSummaryText(recipe)
            )
        )
    }

    private func recipeSummaryText(_ recipe: RecipeSummary) -> String {
        var parts: [String] = []
        if !recipe.cuisine.isEmpty { parts.append(recipe.cuisine) }
        if !recipe.mealType.isEmpty { parts.append(recipe.mealType) }
        if let servings = recipe.servings { parts.append("\(Int(servings)) servings") }
        return parts.joined(separator: " · ")
    }

    /// Upsert an IngredientPreference with `choice_mode = avoid` or
    /// `allergy` keyed on the recipe ingredient's baseIngredientId, then
    /// flash a toast. Next time the planner runs, the AI won't propose
    /// meals with this ingredient. Existing recipes in the library are
    /// unaffected — those are data, not plans.
    private func showCookingCompletionToast() {
        preferenceToast = "Nicely done."
        let snapshot = preferenceToast
        Task {
            try? await Task.sleep(for: .seconds(2))
            if preferenceToast == snapshot {
                preferenceToast = nil
            }
        }
    }

    private func markPreference(ingredient: RecipeIngredient, mode: String) async {
        guard let baseID = ingredient.baseIngredientId, !baseID.isEmpty else { return }
        do {
            _ = try await appState.upsertIngredientPreference(
                baseIngredientID: baseID,
                choiceMode: mode
            )
            let verb = mode == "allergy" ? "Allergy noted" : "Avoiding"
            preferenceToast = "\(verb): \(ingredient.ingredientName)"
            // Auto-dismiss the toast after ~2s. A new mark will overwrite.
            let snapshot = preferenceToast
            try? await Task.sleep(for: .seconds(2))
            if preferenceToast == snapshot {
                preferenceToast = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleFavorite(_ recipe: RecipeSummary) async {
        var draft = recipe.editingDraft()
        draft.favorite = !recipe.favorite
        do {
            _ = try await appState.saveRecipe(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateVariation(_ recipe: RecipeSummary, goal: RecipeVariationGoal) async {
        isGeneratingVariation = true
        defer { isGeneratingVariation = false }

        do {
            let aiDraft = try await appState.generateRecipeVariationDraft(recipeID: recipe.recipeId, goal: goal.title)
            // M29 build 55 — variation drafts now go through the
            // review sheet so the user can refine ("less spice")
            // before the variant lands in the library.
            pendingReviewDraft = PendingReviewDraft(
                draft: aiDraft.draft,
                contextHint: "a \(aiDraft.goal.lowercased()) variation of \"\(recipe.name)\""
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateCompanions(_ recipe: RecipeSummary) async {
        isGeneratingCompanions = true
        defer { isGeneratingCompanions = false }

        do {
            let options = try await appState.generateRecipeCompanionDrafts(recipeID: recipe.recipeId)
            companionContext = RecipeCompanionSheetContext(
                title: "\(recipe.name) Companions",
                options: options
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ recipe: RecipeSummary) async {
        do {
            try await appState.restoreRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ recipe: RecipeSummary) async {
        do {
            try await appState.deleteRecipe(recipe)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func regenerateImage(_ recipe: RecipeSummary) async {
        guard !isRegeneratingImage else { return }
        isRegeneratingImage = true
        defer { isRegeneratingImage = false }
        do {
            try await appState.regenerateRecipeImage(recipeID: recipe.recipeId)
        } catch {
            imageActionToast = "Couldn't regenerate image: \(error.localizedDescription)"
        }
    }

    private func removeImage() async {
        do {
            try await appState.deleteRecipeImage(recipeID: recipeID)
        } catch {
            imageActionToast = "Couldn't remove image: \(error.localizedDescription)"
        }
    }

    private func formatRecipeForSharing(_ recipe: RecipeSummary) -> String {
        var lines: [String] = []

        lines.append(recipe.name)

        // Metadata line
        var meta: [String] = []
        if let servings = recipe.servings {
            meta.append("Serves \(servings.formatted())")
        }
        if let prep = recipe.prepMinutes, prep > 0 {
            meta.append("Prep: \(prep)m")
        }
        if let cook = recipe.cookMinutes, cook > 0 {
            meta.append("Cook: \(cook)m")
        }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " | "))
        }

        // Ingredients
        if !recipe.ingredients.isEmpty {
            lines.append("")
            lines.append("Ingredients:")
            for ingredient in recipe.ingredients {
                var parts: [String] = []
                if let quantity = ingredient.quantity {
                    parts.append(quantity.formatted())
                }
                if !ingredient.unit.isEmpty {
                    parts.append(ingredient.unit)
                }
                parts.append(ingredient.ingredientName)
                if !ingredient.prep.isEmpty {
                    parts.append(ingredient.prep)
                }
                lines.append("- \(parts.joined(separator: " "))")
            }
        }

        // Steps
        if !recipe.steps.isEmpty {
            lines.append("")
            lines.append("Steps:")
            for step in recipe.steps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                lines.append("\(step.sortOrder). \(step.instruction)")
                for substep in step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    lines.append("   \(substep.instruction)")
                }
            }
        } else if !recipe.instructionsSummary.isEmpty {
            lines.append("")
            lines.append("Instructions:")
            lines.append(recipe.instructionsSummary)
        }

        // Notes
        if !recipe.notes.isEmpty {
            lines.append("")
            lines.append("Notes:")
            lines.append(recipe.notes)
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Companion Options (dark theme)

private struct RecipeCompanionOptionsView: View {
    let context: RecipeCompanionSheetContext
    let onSelect: (RecipeAIDraftOption) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    // Rationale card
                    SMCard {
                        VStack(alignment: .leading, spacing: SMSpacing.sm) {
                            Text(context.options.goal)
                                .font(SMFont.label)
                                .foregroundStyle(SMColor.textTertiary)
                            Text(context.options.rationale)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)
                        }
                    }

                    // Options
                    ForEach(context.options.options) { option in
                        Button {
                            onSelect(option)
                        } label: {
                            SMCard {
                                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                                    HStack {
                                        Text(option.label)
                                            .font(SMFont.subheadline)
                                            .foregroundStyle(SMColor.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundStyle(SMColor.textTertiary)
                                    }
                                    Text(option.draft.name)
                                        .font(SMFont.headline)
                                        .foregroundStyle(SMColor.primary)
                                    Text(option.rationale)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(SMSpacing.lg)
            }
            .paperBackground()
            .scrollContentBackground(.hidden)
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
    }
}
