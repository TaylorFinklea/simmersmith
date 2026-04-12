import SwiftUI
import SimmerSmithKit

struct MealNoteEditor: View {
    let meal: WeekMeal
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var notes: String
    @State private var isSaving = false

    init(meal: WeekMeal, onSave: @escaping (String) async -> Void) {
        self.meal = meal
        self.onSave = onSave
        _notes = State(initialValue: meal.notes)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                VStack(spacing: SMSpacing.lg) {
                    Text(meal.recipeName)
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textPrimary)

                    Text("\(meal.dayName) \(meal.slot.capitalized)")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)

                    TextEditor(text: $notes)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(SMSpacing.md)
                        .background(SMColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                        .frame(minHeight: 120)

                    Spacer()
                }
                .padding(SMSpacing.xl)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            await onSave(notes)
                            dismiss()
                        }
                    }
                    .foregroundStyle(SMColor.primary)
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
