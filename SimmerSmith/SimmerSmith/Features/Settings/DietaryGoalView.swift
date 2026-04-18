import SwiftUI
import SimmerSmithKit

struct DietaryGoalView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var goalType: DietaryGoalType = .maintain
    @State private var dailyCalories: Int = 2000
    @State private var proteinG: Int = 150
    @State private var carbsG: Int = 225
    @State private var fatG: Int = 55
    @State private var fiberG: Int = 28
    @State private var fiberEnabled: Bool = true
    @State private var notes: String = ""
    @State private var isSaving = false
    @State private var isClearing = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Goal", selection: $goalType) {
                    Text("Lose Weight").tag(DietaryGoalType.lose)
                    Text("Maintain").tag(DietaryGoalType.maintain)
                    Text("Gain").tag(DietaryGoalType.gain)
                    Text("Custom").tag(DietaryGoalType.custom)
                }
                .pickerStyle(.segmented)
                .onChange(of: goalType) { _, newValue in
                    if newValue != .custom {
                        syncMacrosFromPreset(for: newValue)
                    }
                }
            } header: {
                Text("Goal Type")
            } footer: {
                Text(goalTypeBlurb)
                    .font(SMFont.caption)
            }

            Section("Daily Calories") {
                Stepper(value: $dailyCalories, in: 800...6000, step: 50) {
                    HStack {
                        Text("Calories")
                        Spacer()
                        Text("\(dailyCalories)")
                            .foregroundStyle(SMColor.primary)
                            .font(SMFont.subheadline.monospacedDigit())
                    }
                }
                .onChange(of: dailyCalories) { _, newValue in
                    if goalType != .custom {
                        syncMacrosFromPreset(for: goalType, calories: newValue)
                    }
                }
            }

            Section("Macros (per person, per day)") {
                macroStepper("Protein", value: $proteinG, range: 0...500, unit: "g")
                macroStepper("Carbs", value: $carbsG, range: 0...800, unit: "g")
                macroStepper("Fat", value: $fatG, range: 0...400, unit: "g")

                Toggle("Track fiber", isOn: $fiberEnabled)
                if fiberEnabled {
                    macroStepper("Fiber", value: $fiberG, range: 0...200, unit: "g")
                }

                HStack {
                    Text("Macros total")
                        .foregroundStyle(SMColor.textSecondary)
                    Spacer()
                    Text("\(macroCalorieTotal) cal")
                        .foregroundStyle(macroCalorieTotal == dailyCalories ? SMColor.textSecondary : SMColor.primary)
                        .font(SMFont.caption.monospacedDigit())
                }
                .font(SMFont.caption)
            }

            Section("Notes") {
                TextField("e.g., low sodium, high-protein dinners", text: $notes, axis: .vertical)
                    .lineLimit(3...5)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(SMColor.destructive)
                        .font(SMFont.caption)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save Goal")
                                .font(SMFont.subheadline)
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving || isClearing)

                if appState.profile?.dietaryGoal != nil {
                    Button(role: .destructive) {
                        Task { await clear() }
                    } label: {
                        HStack {
                            Spacer()
                            if isClearing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Clear Goal")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving || isClearing)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SMColor.surface)
        .navigationTitle("Dietary Goal")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: populateFromProfile)
    }

    // MARK: - Helpers

    private func macroStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.wrappedValue)\(unit)")
                    .foregroundStyle(SMColor.primary)
                    .font(SMFont.subheadline.monospacedDigit())
            }
        }
    }

    private var macroCalorieTotal: Int {
        proteinG * 4 + carbsG * 4 + fatG * 9
    }

    private var goalTypeBlurb: String {
        switch goalType {
        case .lose:
            return "Higher-protein split (40/30/30) for a calorie deficit."
        case .maintain:
            return "Balanced split (30/45/25) for steady intake."
        case .gain:
            return "Carb-leaning split (30/45/25) at a higher calorie target."
        case .custom:
            return "You control each macro directly."
        }
    }

    private func populateFromProfile() {
        guard let goal = appState.profile?.dietaryGoal else {
            syncMacrosFromPreset(for: goalType)
            return
        }
        goalType = goal.goalType
        dailyCalories = goal.dailyCalories
        proteinG = goal.proteinG
        carbsG = goal.carbsG
        fatG = goal.fatG
        if let fiber = goal.fiberG {
            fiberG = fiber
            fiberEnabled = true
        } else {
            fiberEnabled = false
        }
        notes = goal.notes
    }

    private func syncMacrosFromPreset(for type: DietaryGoalType, calories: Int? = nil) {
        let cal = calories ?? dailyCalories
        let splits: (protein: Double, carbs: Double, fat: Double)
        switch type {
        case .lose:
            splits = (0.40, 0.30, 0.30)
        case .maintain, .gain, .custom:
            splits = (0.30, 0.45, 0.25)
        }
        proteinG = Int((Double(cal) * splits.protein / 4).rounded())
        carbsG = Int((Double(cal) * splits.carbs / 4).rounded())
        fatG = Int((Double(cal) * splits.fat / 9).rounded())
    }

    private func save() async {
        let goal = DietaryGoal(
            goalType: goalType,
            dailyCalories: dailyCalories,
            proteinG: proteinG,
            carbsG: carbsG,
            fatG: fatG,
            fiberG: fiberEnabled ? fiberG : nil,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await appState.apiClient.saveDietaryGoal(goal)
            await appState.refreshAll()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clear() async {
        isClearing = true
        errorMessage = nil
        defer { isClearing = false }
        do {
            try await appState.apiClient.clearDietaryGoal()
            await appState.refreshAll()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
