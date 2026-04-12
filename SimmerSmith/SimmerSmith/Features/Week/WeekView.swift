import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedMealForAction: WeekMeal?
    @State private var editingMeal: WeekMeal?
    @State private var navigatingToRecipeID: String?
    @State private var showingActivity = false
    @State private var showingAIPlanner = false
    @State private var showingGrocery = false
    @State private var showingSettings = false
    @State private var aiPrompt = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    if let week = appState.currentWeek {
                        todaySection(week)
                        tomorrowSection(week)
                        restOfWeekSection(week)
                        groceryBar(week)
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, SMSpacing.lg)
                .padding(.bottom, 80)
            }
            .background(SMColor.surface)
            .refreshable {
                await appState.refreshWeek()
            }

            AIFloatingButton {
                if appState.currentWeek == nil {
                    Task { await createWeekAndShowPlanner() }
                } else {
                    showingAIPlanner = true
                }
            }
            .padding(.trailing, SMSpacing.xl)
            .padding(.bottom, SMSpacing.xl)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("SimmerSmith")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: SMSpacing.lg) {
                    Button { showingActivity = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    .accessibilityLabel("View week activity")

                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .confirmationDialog(
            selectedMealForAction?.recipeName ?? "Meal",
            isPresented: Binding(
                get: { selectedMealForAction != nil },
                set: { if !$0 { selectedMealForAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let meal = selectedMealForAction {
                if meal.recipeId != nil {
                    Button("View Recipe") {
                        navigatingToRecipeID = meal.recipeId
                    }
                }
                Button("Edit Notes") {
                    editingMeal = meal
                }
                Button("Mark as Eating Out") {
                    markEatingOut(meal)
                }
                Button("Remove", role: .destructive) {
                    removeMeal(meal)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .navigationDestination(item: $navigatingToRecipeID) { recipeID in
            RecipeDetailView(recipeID: recipeID)
        }
        .sheet(item: $editingMeal) { meal in
            MealNoteEditor(meal: meal) { newNotes in
                await updateMealNotes(meal, notes: newNotes)
            }
        }
        .sheet(isPresented: $showingActivity) {
            NavigationStack { ActivityView() }
        }
        .sheet(isPresented: $showingGrocery) {
            NavigationStack { GroceryView() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showingAIPlanner) {
            aiPlannerSheet
        }
    }

    // MARK: - Today Section

    @ViewBuilder
    private func todaySection(_ week: WeekSnapshot) -> some View {
        let todayMeals = week.meals.filter { Calendar.current.isDateInToday($0.mealDate) }

        VStack(alignment: .leading, spacing: SMSpacing.md) {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text("Today")
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                Text(Date().formatted(date: .abbreviated, time: .omitted))
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)
            }
            .padding(.top, SMSpacing.sm)

            if todayMeals.isEmpty {
                VStack(spacing: SMSpacing.sm) {
                    Text("Nothing planned")
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textSecondary)
                    Text("Tap the sparkle button to plan meals with AI")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SMSpacing.xl)
            } else {
                ForEach(todayMeals) { meal in
                    TodayMealCard(
                        meal: meal,
                        recipe: recipeSummary(for: meal),
                        onTap: { selectedMealForAction = meal }
                    )
                }
            }
        }
    }

    // MARK: - Tomorrow Section

    @ViewBuilder
    private func tomorrowSection(_ week: WeekSnapshot) -> some View {
        let tomorrowMeals = week.meals.filter { Calendar.current.isDateInTomorrow($0.mealDate) }

        if !tomorrowMeals.isEmpty {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                Text("Tomorrow")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)

                ForEach(tomorrowMeals) { meal in
                    CompactMealCard(meal: meal) {
                        selectedMealForAction = meal
                    }
                }
            }
        }
    }

    // MARK: - Rest of Week

    @ViewBuilder
    private func restOfWeekSection(_ week: WeekSnapshot) -> some View {
        let calendar = Calendar.current
        let remainingMeals = week.meals.filter {
            !calendar.isDateInToday($0.mealDate) && !calendar.isDateInTomorrow($0.mealDate)
        }

        if !remainingMeals.isEmpty {
            let grouped = groupedMeals(from: remainingMeals)

            ForEach(grouped, id: \.dayName) { day in
                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                    Text(day.dayName)
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.primary)

                    ForEach(day.meals) { meal in
                        CompactMealCard(meal: meal) {
                            selectedMealForAction = meal
                        }
                    }
                }
            }
        }
    }

    // MARK: - Grocery Bar

    @ViewBuilder
    private func groceryBar(_ week: WeekSnapshot) -> some View {
        if !week.groceryItems.isEmpty {
            Button { showingGrocery = true } label: {
                HStack {
                    Image(systemName: "cart.fill")
                        .foregroundStyle(SMColor.primary)
                    Text("\(week.groceryItems.count) grocery items")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                    Spacer()
                    Text("View list")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(SMColor.primary)
                }
                .padding(SMSpacing.lg)
                .background(SMColor.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                        .strokeBorder(SMColor.primary.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: SMSpacing.xl) {
            Spacer()
                .frame(height: 80)

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.primary.opacity(0.6))

            VStack(spacing: SMSpacing.sm) {
                Text("No Week Yet")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
                Text("Tap the sparkle button to plan your first week with AI.")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, SMSpacing.xxl)
    }

    // MARK: - AI Planner Sheet

    private var aiPlannerSheet: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                VStack(spacing: SMSpacing.xl) {
                    VStack(spacing: SMSpacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(SMColor.primary)

                        Text("Plan My Week")
                            .font(SMFont.display)
                            .foregroundStyle(SMColor.textPrimary)

                        Text("Describe what you'd like to eat and AI will generate a full week of meals with recipes.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, SMSpacing.xl)

                    TextField(
                        "e.g., healthy meals for two, quick dinners, lots of veggies...",
                        text: $aiPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .padding(SMSpacing.lg)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .foregroundStyle(SMColor.textPrimary)

                    if let error = generationError {
                        Text(error)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.destructive)
                            .multilineTextAlignment(.center)
                    }

                    Button { Task { await generatePlan() } } label: {
                        if isGenerating {
                            HStack(spacing: SMSpacing.sm) {
                                ProgressView()
                                    .tint(SMColor.surface)
                                Text("Generating meals...")
                                    .font(SMFont.subheadline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                        } else {
                            Label("Generate Week", systemImage: "wand.and.stars")
                                .font(SMFont.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SMSpacing.lg)
                        }
                    }
                    .foregroundStyle(isGenerating ? SMColor.textSecondary : .white)
                    .background(isGenerating ? SMColor.surfaceElevated : SMColor.primary)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .disabled(isGenerating)

                    Spacer()
                }
                .padding(.horizontal, SMSpacing.xl)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAIPlanner = false }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
    }

    // MARK: - Meal Edit Actions

    private func markEatingOut(_ meal: WeekMeal) {
        guard let week = appState.currentWeek else { return }
        Task {
            var meals = week.meals.map { m in
                MealUpdateRequest(
                    mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                    slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                    servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                    notes: m.notes, approved: m.approved
                )
            }
            if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
                meals[idx] = MealUpdateRequest(
                    mealId: meal.mealId, dayName: meal.dayName,
                    mealDate: meal.mealDate, slot: meal.slot,
                    recipeName: "Eating Out", approved: true
                )
            }
            _ = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
        }
    }

    private func removeMeal(_ meal: WeekMeal) {
        guard let week = appState.currentWeek else { return }
        Task {
            let meals = week.meals
                .filter { $0.mealId != meal.mealId }
                .map { m in
                    MealUpdateRequest(
                        mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                        slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                        servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                        notes: m.notes, approved: m.approved
                    )
                }
            _ = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
        }
    }

    private func updateMealNotes(_ meal: WeekMeal, notes: String) async {
        guard let week = appState.currentWeek else { return }
        var meals = week.meals.map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate,
                slot: m.slot, recipeId: m.recipeId, recipeName: m.recipeName,
                servings: m.servings, scaleMultiplier: m.scaleMultiplier,
                notes: m.notes, approved: m.approved
            )
        }
        if let idx = meals.firstIndex(where: { $0.mealId == meal.mealId }) {
            meals[idx] = MealUpdateRequest(
                mealId: meal.mealId, dayName: meal.dayName,
                mealDate: meal.mealDate, slot: meal.slot,
                recipeId: meal.recipeId, recipeName: meal.recipeName,
                servings: meal.servings, scaleMultiplier: meal.scaleMultiplier,
                notes: notes, approved: meal.approved
            )
        }
        _ = try? await appState.saveWeekMeals(weekID: week.weekId, meals: meals)
    }

    // MARK: - Actions

    private func createWeekAndShowPlanner() async {
        let calendar = Calendar.current
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today)!

        do {
            _ = try await appState.createWeek(weekStart: monday)
            await appState.refreshWeek()
            showingAIPlanner = true
        } catch {
            appState.lastErrorMessage = error.localizedDescription
        }
    }

    private func generatePlan() async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        isGenerating = true
        generationError = nil
        do {
            _ = try await appState.generateWeekFromAI(weekID: weekID, prompt: aiPrompt)
            showingAIPlanner = false
        } catch {
            generationError = error.localizedDescription
        }
        isGenerating = false
    }

    // MARK: - Helpers

    private func recipeSummary(for meal: WeekMeal) -> RecipeSummary? {
        guard let recipeId = meal.recipeId else { return nil }
        return appState.recipes.first { $0.recipeId == recipeId }
    }

    private func groupedMeals(from meals: [WeekMeal]) -> [(dayName: String, meals: [WeekMeal])] {
        let grouped = Dictionary(grouping: meals, by: \.dayName)
        return grouped
            .map { key, value in
                (key, value.sorted { ($0.mealDate, $0.slot) < ($1.mealDate, $1.slot) })
            }
            .sorted { ($0.meals.first?.mealDate ?? .distantFuture) < ($1.meals.first?.mealDate ?? .distantFuture) }
    }
}
