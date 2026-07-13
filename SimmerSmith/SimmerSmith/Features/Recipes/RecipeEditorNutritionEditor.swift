import SwiftUI
import SimmerSmithKit

struct NutritionEditor: View {
    let nutritionSummary: NutritionSummary?
    let isEstimatingNutrition: Bool
    let nutritionEstimateError: String?

    var body: some View {
        Section("Calories") {
            if let nutritionSummary {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let caloriesPerServing = nutritionSummary.caloriesPerServing {
                            Text("\(Int(caloriesPerServing.rounded())) calories per serving")
                                .font(.headline)
                        } else if let totalCalories = nutritionSummary.totalCalories {
                            Text("\(Int(totalCalories.rounded())) calories total")
                                .font(.headline)
                        } else {
                            Text("No calorie estimate yet")
                                .font(.headline)
                        }

                        Text(nutritionSummary.statusLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isEstimatingNutrition {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("\(nutritionSummary.matchedIngredientCount) matched • \(nutritionSummary.unmatchedIngredientCount) unmatched")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !nutritionSummary.unmatchedIngredients.isEmpty {
                    ForEach(nutritionSummary.unmatchedIngredients, id: \.self) { ingredient in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ingredient)
                                    .foregroundStyle(.primary)
                                Text("No catalog nutrition data yet")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "questionmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } else if isEstimatingNutrition {
                ProgressView("Calculating calories…")
            } else {
                Text("Calories update from the current ingredient list and servings.")
                    .foregroundStyle(.secondary)
            }

            if let nutritionEstimateError {
                Text(nutritionEstimateError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}
