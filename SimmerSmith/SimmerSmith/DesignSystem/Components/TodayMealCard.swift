import SwiftUI
import SimmerSmithKit

/// "Tonight" hero card on WeekView. Index-card paper treatment with
/// washi tape, riveted corners, ember `◆ AT THE FORGE` eyebrow, and
/// the meal name in italic Instrument Serif.
struct TodayMealCard: View {
    let meal: WeekMeal
    let recipe: RecipeSummary?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            FuIndexCard(rotation: -0.5, washi: SMColor.risoYellow, rivets: true) {
                VStack(alignment: .leading, spacing: SMSpacing.sm) {
                    HStack {
                        FuEyebrow(text: "tonight · \(meal.slot.lowercased())")

                        Spacer()

                        FuEyebrow(text: "◆ at the forge", ember: true)
                    }

                    Text(meal.recipeName)
                        .font(SMFont.serifDisplay(24))
                        .foregroundStyle(SMColor.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    if !meal.sides.isEmpty {
                        SideChipRow(sides: meal.sides)
                    }

                    HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                        .padding(.top, 4)

                    HStack(spacing: SMSpacing.md) {
                        if let prep = recipe?.prepMinutes, prep > 0 {
                            TimeBadge(minutes: prep)
                        }
                        if let cook = recipe?.cookMinutes, cook > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "flame")
                                    .font(.system(size: 11))
                                    .foregroundStyle(SMColor.ember)
                                Text("\(cook)m")
                                    .font(SMFont.handwritten(13))
                                    .foregroundStyle(SMColor.ember)
                            }
                        }
                        Spacer()
                        if meal.approved {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                Text("done")
                                    .font(SMFont.handwritten(14))
                            }
                            .foregroundStyle(SMColor.ember)
                        } else {
                            Text("fire up →")
                                .font(SMFont.handwritten(14, bold: true))
                                .foregroundStyle(SMColor.ember)
                        }
                    }

                    if !meal.notes.isEmpty {
                        Text(meal.notes)
                            .font(SMFont.bodySerifItalic(13))
                            .foregroundStyle(SMColor.inkSoft)
                            .lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
