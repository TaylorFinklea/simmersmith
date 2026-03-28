import SwiftUI
import SimmerSmithKit

struct WeekView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedMeal: WeekMeal?
    @State private var showingActivity = false

    var body: some View {
        Group {
            if let week = appState.currentWeek {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Current Week")
                                .font(.headline)
                            Text(week.weekStart.formatted(date: .abbreviated, time: .omitted))
                                .font(.title3.weight(.semibold))
                            Text(statusSummary(for: week))
                                .foregroundStyle(.secondary)
                            HStack {
                                Label("\(week.meals.count) meals", systemImage: "fork.knife")
                                Spacer()
                                Label("\(week.feedbackCount) feedback", systemImage: "bubble.left")
                                Spacer()
                                Label("\(week.exportCount) exports", systemImage: "square.and.arrow.up")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }

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
                ContentUnavailableView(
                    "No Current Week",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Create or sync a week from the server to see meals here.")
                )
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

                    Button {
                        Task { await appState.refreshWeek() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
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
    }

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
