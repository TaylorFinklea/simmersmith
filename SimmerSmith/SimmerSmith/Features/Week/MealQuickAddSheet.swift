import SwiftUI
import SimmerSmithKit

struct MealQuickAddSheet: View {
    let dayName: String
    let mealDate: Date
    let slot: String
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mealName = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                SMColor.surface.ignoresSafeArea()

                VStack(spacing: SMSpacing.lg) {
                    VStack(spacing: SMSpacing.xs) {
                        Text("Add \(slot.capitalized)")
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.textPrimary)

                        Text(dayName)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                    .padding(.top, SMSpacing.lg)

                    TextField("e.g., leftover pizza, grilled chicken...", text: $mealName)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textPrimary)
                        .padding(SMSpacing.lg)
                        .background(SMColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                        .submitLabel(.done)
                        .onSubmit { saveIfValid() }

                    Spacer()
                }
                .padding(.horizontal, SMSpacing.xl)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveIfValid() }
                        .foregroundStyle(mealName.trimmingCharacters(in: .whitespaces).isEmpty ? SMColor.textTertiary : SMColor.primary)
                        .disabled(mealName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveIfValid() {
        let trimmed = mealName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            await onSave(trimmed)
            dismiss()
        }
    }
}
