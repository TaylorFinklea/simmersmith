import SwiftUI
import SimmerSmithKit

struct MealMoveSheet: View {
    let meal: WeekMeal
    let week: WeekSnapshot
    let onMove: (String, Date, String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isMoving = false

    private static let allSlots = ["breakfast", "lunch", "dinner"]
    private static let dayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private var weekDays: [(name: String, date: Date)] {
        let calendar = Calendar.current
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: week.weekStart)!
            let name = Self.dayNames[offset % Self.dayNames.count]
            return (name: name, date: date)
        }
    }

    private func existingMeal(dayDate: Date, slot: String) -> WeekMeal? {
        let calendar = Calendar.current
        return week.meals.first {
            calendar.isDate($0.mealDate, inSameDayAs: dayDate) && $0.slot == slot
        }
    }

    private func isCurrentSlot(dayDate: Date, slot: String) -> Bool {
        let calendar = Calendar.current
        return calendar.isDate(meal.mealDate, inSameDayAs: dayDate) && meal.slot == slot
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: SMSpacing.lg) {
                        VStack(spacing: SMSpacing.xs) {
                            Text("Move Meal")
                                .font(SMFont.headline)
                                .foregroundStyle(SMColor.textPrimary)

                            Text(meal.recipeName)
                                .font(SMFont.body)
                                .foregroundStyle(SMColor.textSecondary)

                            Text("\(meal.dayName) \(meal.slot.capitalized)")
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                        .padding(.top, SMSpacing.lg)

                        ForEach(weekDays, id: \.date) { day in
                            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                                HStack {
                                    Text(day.name)
                                        .font(SMFont.subheadline)
                                        .foregroundStyle(SMColor.primary)

                                    Spacer()

                                    Text(day.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textTertiary)
                                }
                                .padding(.horizontal, SMSpacing.sm)

                                ForEach(Self.allSlots, id: \.self) { slot in
                                    let isCurrent = isCurrentSlot(dayDate: day.date, slot: slot)
                                    let existing = existingMeal(dayDate: day.date, slot: slot)

                                    Button {
                                        guard !isCurrent, !isMoving else { return }
                                        isMoving = true
                                        Task {
                                            await onMove(day.name, day.date, slot)
                                            dismiss()
                                        }
                                    } label: {
                                        HStack(spacing: SMSpacing.md) {
                                            Text(slot.capitalized)
                                                .font(SMFont.label)
                                                .foregroundStyle(isCurrent ? SMColor.primary : SMColor.textTertiary)
                                                .frame(width: 64, alignment: .leading)

                                            if isCurrent {
                                                HStack(spacing: SMSpacing.xs) {
                                                    Image(systemName: "pin.fill")
                                                        .font(.caption2)
                                                    Text("Current")
                                                }
                                                .font(SMFont.caption)
                                                .foregroundStyle(SMColor.primary)
                                            } else if let existing {
                                                HStack(spacing: SMSpacing.xs) {
                                                    Image(systemName: "arrow.triangle.swap")
                                                        .font(.caption2)
                                                    Text(existing.recipeName)
                                                }
                                                .font(SMFont.caption)
                                                .foregroundStyle(SMColor.accent)
                                                .lineLimit(1)
                                            } else {
                                                HStack(spacing: SMSpacing.xs) {
                                                    Image(systemName: "circle.dashed")
                                                        .font(.caption2)
                                                    Text("Empty")
                                                }
                                                .font(SMFont.caption)
                                                .foregroundStyle(SMColor.textTertiary)
                                            }

                                            Spacer()

                                            if !isCurrent {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(SMColor.textTertiary)
                                            }
                                        }
                                        .padding(.horizontal, SMSpacing.md)
                                        .padding(.vertical, SMSpacing.sm)
                                        .background(isCurrent ? SMColor.primary.opacity(0.1) : SMColor.surfaceCard)
                                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isCurrent || isMoving)
                                }
                            }
                            .padding(.horizontal, SMSpacing.md)
                        }
                    }
                    .padding(.horizontal, SMSpacing.md)
                    .padding(.bottom, SMSpacing.xxl)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        .presentationDetents([.large])
    }
}
