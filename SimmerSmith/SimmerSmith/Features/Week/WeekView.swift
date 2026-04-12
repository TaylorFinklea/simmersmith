import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedMeal: WeekMeal?
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
                        weekHeader(week)
                        dayCards(week)
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

            // AI Floating Action Button
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
        .sheet(item: $selectedMeal) { meal in
            FeedbackComposerView(title: meal.recipeName) { sentiment, notes in
                try await appState.submitMealFeedback(for: meal, sentiment: sentiment, notes: notes)
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

    // MARK: - Week Header

    @ViewBuilder
    private func weekHeader(_ week: WeekSnapshot) -> some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text("This Week")
                    .font(SMFont.display)
                    .foregroundStyle(SMColor.textPrimary)

                Text(week.weekStart.formatted(date: .abbreviated, time: .omitted))
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)

                HStack(spacing: SMSpacing.lg) {
                    Label("\(week.meals.count) meals", systemImage: "fork.knife")
                    Label(statusLabel(for: week), systemImage: "circle.fill")
                        .foregroundStyle(week.status == "approved" ? SMColor.success : SMColor.textTertiary)
                }
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textSecondary)
            }
        }
        .padding(.top, SMSpacing.sm)
    }

    // MARK: - Day Cards

    @ViewBuilder
    private func dayCards(_ week: WeekSnapshot) -> some View {
        let grouped = groupedMeals(for: week)
        ForEach(grouped, id: \.dayName) { day in
            DayCard(dayName: day.dayName, meals: day.meals)
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

    private func statusLabel(for week: WeekSnapshot) -> String {
        week.status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func groupedMeals(for week: WeekSnapshot) -> [(dayName: String, meals: [WeekMeal])] {
        let grouped = Dictionary(grouping: week.meals, by: \.dayName)
        return grouped
            .map { key, value in
                (key, value.sorted { ($0.mealDate, $0.slot) < ($1.mealDate, $1.slot) })
            }
            .sorted { ($0.meals.first?.mealDate ?? .distantFuture) < ($1.meals.first?.mealDate ?? .distantFuture) }
    }
}
