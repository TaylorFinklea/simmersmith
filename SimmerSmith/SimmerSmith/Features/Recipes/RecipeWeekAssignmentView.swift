import SwiftUI
import SimmerSmithKit

private enum AssignmentConflictAction: String, CaseIterable, Identifiable {
    case replace
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace:
            "Replace"
        case .skip:
            "Skip"
        }
    }
}

private struct RecipeAssignment: Identifiable, Hashable {
    let recipeID: String
    let recipeName: String
    let recipeSummary: RecipeSummary
    var dayOffset: Int
    var slot: MealSlotOption
    var scale: RecipeScaleOption
    var conflictAction: AssignmentConflictAction

    var id: String { recipeID }
}

struct RecipeWeekAssignmentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let recipes: [RecipeSummary]

    @State private var weekStart: Date
    @State private var assignments: [RecipeAssignment]
    @State private var targetWeek: WeekSnapshot?
    @State private var isLoadingWeek = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(recipes: [RecipeSummary]) {
        self.recipes = recipes
        let defaultWeekStart = Self.defaultWeekStart()
        _weekStart = State(initialValue: defaultWeekStart)
        _assignments = State(
            initialValue: recipes.enumerated().map { index, recipe in
                RecipeAssignment(
                    recipeID: recipe.recipeId,
                    recipeName: recipe.name,
                    recipeSummary: recipe,
                    dayOffset: min(index, 6),
                    slot: defaultMealSlot(for: recipe.mealType),
                    scale: .single,
                    conflictAction: .replace
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Week") {
                    DatePicker(
                        "Week of",
                        selection: $weekStart,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)

                    if isLoadingWeek {
                        ProgressView("Loading week…")
                    } else if let targetWeek {
                        Text("Editing \(targetWeek.weekStart.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A new week will be created if one does not already exist.")
                            .foregroundStyle(.secondary)
                    }
                }

                if hasDuplicateAssignments {
                    Section {
                        Text("Two selected recipes are mapped to the same day and slot. Adjust the assignments before saving.")
                            .foregroundStyle(.red)
                    }
                }

                ForEach($assignments) { $assignment in
                    Section(assignment.recipeName) {
                        Picker("Day", selection: $assignment.dayOffset) {
                            ForEach(dayOptions, id: \.offset) { option in
                                Text(option.title).tag(option.offset)
                            }
                        }

                        Picker("Slot", selection: $assignment.slot) {
                            ForEach(MealSlotOption.allCases) { slot in
                                Text(slot.title).tag(slot)
                            }
                        }

                        Picker("Scale", selection: $assignment.scale) {
                            ForEach(RecipeScaleOption.allCases) { scale in
                                Text(scale.title).tag(scale)
                            }
                        }

                        if let conflictMeal = conflictMeal(for: assignment) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Existing meal")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(conflictMeal.dayName) \(conflictMeal.slot.capitalized): \(conflictMeal.recipeName)")
                                Picker("If occupied", selection: $assignment.conflictAction) {
                                    ForEach(AssignmentConflictAction.allCases) { action in
                                        Text(action.title).tag(action)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle(recipes.count == 1 ? "Add to Week" : "Plan Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await saveAssignments() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isSaving || isLoadingWeek || hasDuplicateAssignments)
                }
            }
            .smithToolbar()
            .task(id: normalizedWeekStart.timeIntervalSinceReferenceDate) {
                await loadTargetWeek()
            }
        }
    }

    private var normalizedWeekStart: Date {
        Self.normalizeWeekStart(weekStart)
    }

    private var dayOptions: [(offset: Int, title: String)] {
        (0..<7).compactMap { offset in
            guard let date = Calendar.isoWeek.date(byAdding: .day, value: offset, to: normalizedWeekStart) else {
                return nil
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE, MMM d"
            return (offset, formatter.string(from: date))
        }
    }

    private var hasDuplicateAssignments: Bool {
        var seen = Set<String>()
        for assignment in assignments {
            let key = "\(assignment.dayOffset)-\(assignment.slot.rawValue)"
            if !seen.insert(key).inserted {
                return true
            }
        }
        return false
    }

    private func loadTargetWeek() async {
        isLoadingWeek = true
        errorMessage = nil
        defer { isLoadingWeek = false }

        do {
            targetWeek = try await appState.fetchWeekByStart(normalizedWeekStart)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func conflictMeal(for assignment: RecipeAssignment) -> WeekMeal? {
        guard let targetWeek else { return nil }
        let slot = assignment.slot.rawValue
        let dayName = dayName(for: assignment.dayOffset)
        return targetWeek.meals.first { $0.dayName == dayName && $0.slot.localizedCaseInsensitiveCompare(slot) == .orderedSame }
    }

    private func saveAssignments() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let week = try await resolveTargetWeek()
            var finalMeals = week.meals.map { $0.asMealUpdateRequest() }

            for assignment in assignments {
                let slot = assignment.slot.rawValue
                let mealDate = Self.mealDate(for: assignment.dayOffset, weekStart: normalizedWeekStart)
                let dayName = dayName(for: assignment.dayOffset)

                if let conflictIndex = finalMeals.firstIndex(where: { $0.dayName == dayName && $0.slot.localizedCaseInsensitiveCompare(slot) == .orderedSame }) {
                    if assignment.conflictAction == .skip {
                        continue
                    }
                    let existing = finalMeals[conflictIndex]
                    finalMeals[conflictIndex] = MealUpdateRequest(
                        mealId: existing.mealId,
                        dayName: dayName,
                        mealDate: mealDate,
                        slot: slot,
                        recipeId: assignment.recipeSummary.recipeId,
                        recipeName: assignment.recipeSummary.name,
                        servings: assignment.recipeSummary.servings.map { $0 * assignment.scale.rawValue },
                        scaleMultiplier: assignment.scale.rawValue,
                        notes: "",
                        approved: false
                    )
                } else {
                    finalMeals.append(
                        MealUpdateRequest(
                            dayName: dayName,
                            mealDate: mealDate,
                            slot: slot,
                            recipeId: assignment.recipeSummary.recipeId,
                            recipeName: assignment.recipeSummary.name,
                            servings: assignment.recipeSummary.servings.map { $0 * assignment.scale.rawValue },
                            scaleMultiplier: assignment.scale.rawValue,
                            notes: "",
                            approved: false
                        )
                    )
                }
            }

            _ = try await appState.saveWeekMeals(weekID: week.weekId, meals: finalMeals)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveTargetWeek() async throws -> WeekSnapshot {
        if let targetWeek {
            return targetWeek
        }
        let createdWeek = try await appState.createWeek(weekStart: normalizedWeekStart)
        targetWeek = createdWeek
        return createdWeek
    }

    private func dayName(for offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: Self.mealDate(for: offset, weekStart: normalizedWeekStart))
    }

    private static func mealDate(for offset: Int, weekStart: Date) -> Date {
        Calendar.isoWeek.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
    }

    private static func normalizeWeekStart(_ date: Date) -> Date {
        Calendar.isoWeek.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    private static func defaultWeekStart() -> Date {
        let currentWeek = normalizeWeekStart(.now)
        return Calendar.isoWeek.date(byAdding: .day, value: 7, to: currentWeek) ?? currentWeek
    }
}

private extension Calendar {
    static let isoWeek: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }()
}
