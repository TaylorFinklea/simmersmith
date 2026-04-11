import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedMeal: WeekMeal?
    @State private var showingActivity = false
    @State private var showingAIPlanner = false
    @State private var aiPrompt = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        Group {
            if let week = appState.currentWeek {
                List {
                    // AI Planner prompt bar
                    Section {
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.purple)
                                Text("Plan with AI")
                                    .font(.headline)
                                Spacer()
                            }
                            Button {
                                showingAIPlanner = true
                            } label: {
                                Label(
                                    week.meals.isEmpty ? "Generate meals for this week" : "Regenerate with AI",
                                    systemImage: "wand.and.stars"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                        }
                        .padding(.vertical, 8)
                    }

                    // Week summary
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(week.weekStart.formatted(date: .abbreviated, time: .omitted))
                                .font(.title3.weight(.semibold))
                            Text(statusSummary(for: week))
                                .foregroundStyle(.secondary)
                            HStack {
                                Label("\(week.meals.count) meals", systemImage: "fork.knife")
                                Spacer()
                                Label("\(week.groceryItems.count) groceries", systemImage: "cart")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    // Meals by day
                    ForEach(groupedMeals(for: week), id: \.dayName) { day in
                        Section(day.dayName) {
                            ForEach(day.meals) { meal in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(meal.slot.capitalized)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if meal.approved {
                                            Label("Approved", systemImage: "checkmark.seal.fill")
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                    Text(meal.recipeName)
                                        .font(.body.weight(.medium))
                                    if meal.scaleMultiplier != 1 {
                                        Text("Scaled \(meal.scaleMultiplier.formatted())x")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !meal.notes.isEmpty {
                                        Text(meal.notes)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .swipeActions {
                                    Button("Feedback", systemImage: "bubble.left") {
                                        selectedMeal = meal
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshWeek()
                }
            } else {
                // Empty state — prompt to create a week and plan with AI
                ContentUnavailableView {
                    Label("No Current Week", systemImage: "calendar.badge.plus")
                } description: {
                    Text("Create a week and let AI plan your meals.")
                } actions: {
                    Button {
                        Task { await createWeekAndShowPlanner() }
                    } label: {
                        Label("Start This Week", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
            }
        }
        .navigationTitle("Week")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandToolbarBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {
                        showingActivity = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("View week activity")

                    Button {
                        Task { await appState.refreshWeek() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh week")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text(appState.syncStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)
        }
        .sheet(item: $selectedMeal) { meal in
            FeedbackComposerView(title: meal.recipeName) { sentiment, notes in
                try await appState.submitMealFeedback(for: meal, sentiment: sentiment, notes: notes)
            }
        }
        .sheet(isPresented: $showingActivity) {
            NavigationStack {
                ActivityView()
            }
        }
        .sheet(isPresented: $showingAIPlanner) {
            aiPlannerSheet
        }
    }

    // MARK: - AI Planner Sheet

    private var aiPlannerSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AI Meal Planner", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.purple)
                        Text("Describe what you'd like to eat this week. The AI will generate a full meal plan with recipes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("What sounds good?") {
                    TextField(
                        "e.g., healthy meals for two, quick dinners, lots of veggies...",
                        text: $aiPrompt,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                }

                if let error = generationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button {
                        Task { await generatePlan() }
                    } label: {
                        if isGenerating {
                            HStack {
                                ProgressView()
                                Text("Generating meals...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Generate Week", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(isGenerating)
                }
            }
            .navigationTitle("Plan My Week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingAIPlanner = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func createWeekAndShowPlanner() async {
        // Find the Monday of this week
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

    private func statusSummary(for week: WeekSnapshot) -> String {
        var parts = [week.status.replacingOccurrences(of: "_", with: " ").capitalized]
        if let approvedAt = week.approvedAt {
            parts.append("Approved \(approvedAt.formatted(date: .abbreviated, time: .shortened))")
        } else if let readyForAiAt = week.readyForAiAt {
            parts.append("Ready for AI \(readyForAiAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " • ")
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
