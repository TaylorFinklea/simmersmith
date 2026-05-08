import SwiftUI
import SimmerSmithKit

struct DayNutritionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let dayName: String
    let date: Date
    let meals: [WeekMeal]
    let totals: MacroBreakdown

    private var goal: DietaryGoal? { appState.profile?.dietaryGoal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SMSpacing.lg) {
                    VStack(alignment: .leading, spacing: SMSpacing.xs) {
                        Text(dayName)
                            .font(SMFont.display)
                            .foregroundStyle(SMColor.textPrimary)
                        Text(DayKey.shortMonthDay(date))
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    summaryCard

                    if let goal {
                        targetsCard(goal: goal)
                    }

                    mealsList
                }
                .padding(SMSpacing.lg)
            }
            .paperBackground()
            .navigationTitle("Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.medium, .large])
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            Text("Today's totals")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)

            MacroRing(macros: totals, goal: goal, compact: false)
        }
        .padding(SMSpacing.lg)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func targetsCard(goal: DietaryGoal) -> some View {
        let protein = macroStatus(actual: totals.proteinG, target: Double(goal.proteinG))
        let carbs = macroStatus(actual: totals.carbsG, target: Double(goal.carbsG))
        let fat = macroStatus(actual: totals.fatG, target: Double(goal.fatG))

        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Text("Target gaps")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)

            targetRow(label: "Protein", actual: totals.proteinG, target: goal.proteinG, status: protein)
            targetRow(label: "Carbs", actual: totals.carbsG, target: goal.carbsG, status: carbs)
            targetRow(label: "Fat", actual: totals.fatG, target: goal.fatG, status: fat)
            if let fiberTarget = goal.fiberG {
                let fiber = macroStatus(actual: totals.fiberG, target: Double(fiberTarget))
                targetRow(label: "Fiber", actual: totals.fiberG, target: fiberTarget, status: fiber)
            }
        }
        .padding(SMSpacing.lg)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
    }

    private func targetRow(label: String, actual: Double, target: Int, status: MacroStatus) -> some View {
        HStack {
            Text(label)
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textPrimary)
            Spacer()
            Text("\(Int(actual))g / \(target)g")
                .font(SMFont.caption.monospacedDigit())
                .foregroundStyle(SMColor.textSecondary)
            Text(status.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.horizontal, SMSpacing.xs)
                .padding(.vertical, 2)
                .background(status.color.opacity(0.12), in: Capsule())
        }
    }

    private var mealsList: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            Text("Meals")
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
            if meals.isEmpty {
                Text("No meals logged for this day.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
            } else {
                ForEach(meals) { meal in
                    HStack(alignment: .top, spacing: SMSpacing.md) {
                        Text(meal.slot.capitalized)
                            .font(SMFont.label)
                            .foregroundStyle(SMColor.textTertiary)
                            .frame(width: 80, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(meal.recipeName)
                                .font(SMFont.subheadline)
                                .foregroundStyle(SMColor.textPrimary)
                            if let m = meal.macros {
                                Text("\(Int(m.calories)) cal · \(Int(m.proteinG))P · \(Int(m.carbsG))C · \(Int(m.fatG))F")
                                    .font(SMFont.caption.monospacedDigit())
                                    .foregroundStyle(SMColor.textSecondary)
                            } else {
                                Text("Nutrition unavailable")
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                        }

                        Spacer()
                    }
                    .padding(SMSpacing.md)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                }
            }
        }
    }

    // MARK: - Status classification

    private enum MacroStatus {
        case onTrack
        case close
        case drift

        var label: String {
            switch self {
            case .onTrack: return "On track"
            case .close: return "Close"
            case .drift: return "Drift"
            }
        }

        var color: Color {
            switch self {
            case .onTrack: return SMColor.success
            case .close: return .orange
            case .drift: return SMColor.destructive
            }
        }
    }

    private func macroStatus(actual: Double, target: Double) -> MacroStatus {
        guard target > 0 else { return .close }
        let ratio = actual / target
        if ratio >= 0.9 && ratio <= 1.1 { return .onTrack }
        if ratio >= 0.75 && ratio <= 1.25 { return .close }
        return .drift
    }
}
