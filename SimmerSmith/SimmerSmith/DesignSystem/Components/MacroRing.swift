import SwiftUI
import SimmerSmithKit

extension MacroBreakdown {
    /// True when every macro value is zero — usually means nutrition data
    /// wasn't available for the underlying meals.
    var isEmpty: Bool {
        calories == 0 && proteinG == 0 && carbsG == 0 && fatG == 0 && fiberG == 0
    }
}

/// Compact calorie ring with three macro bars underneath. Used on each day
/// card to signal at-a-glance whether the day lands near the user's target.
/// In Fusion: ink/paper track, ember/risoGreen/bronze macro accents,
/// monospaced numerics, Caveat unit labels.
struct MacroRing: View {
    let macros: MacroBreakdown
    let goal: DietaryGoal?
    var compact: Bool = true

    private var calorieProgress: Double {
        guard let target = goal?.dailyCalories, target > 0 else { return 0 }
        return min(macros.calories / Double(target), 1.5)
    }

    private var calorieRatio: Double {
        guard let target = goal?.dailyCalories, target > 0 else { return 0 }
        return macros.calories / Double(target)
    }

    private var calorieTintColor: Color {
        guard goal != nil else { return SMColor.inkSoft }
        let ratio = calorieRatio
        if ratio >= 0.9 && ratio <= 1.1 { return SMColor.risoGreen }
        if ratio >= 0.75 && ratio <= 1.25 { return SMColor.ember }
        return SMColor.destructive
    }

    private func macroBar(label: String, value: Double, target: Int?, color: Color) -> some View {
        let targetValue = max(Double(target ?? 0), 1.0)
        let progress = min(value / targetValue, 1.5)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(label)
                    .font(SMFont.handwritten(13))
                    .foregroundStyle(SMColor.inkSoft)
                Spacer()
                Text("\(Int(value))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SMColor.ink)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SMColor.rule.opacity(0.5))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 3)
        }
    }

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            ZStack {
                Circle()
                    .stroke(SMColor.rule.opacity(0.5), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: calorieProgress)
                    .stroke(calorieTintColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(macros.calories))")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(SMColor.ink)
                    if let target = goal?.dailyCalories {
                        Text("/\(target)")
                            .font(.system(size: 9, weight: .medium).monospacedDigit())
                            .foregroundStyle(SMColor.inkSoft)
                    } else {
                        Text("cal")
                            .font(SMFont.handwritten(11))
                            .foregroundStyle(SMColor.inkSoft)
                    }
                }
            }
            .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)

            VStack(spacing: compact ? 2 : 4) {
                macroBar(label: "p", value: macros.proteinG, target: goal?.proteinG, color: SMColor.ember)
                macroBar(label: "c", value: macros.carbsG, target: goal?.carbsG, color: SMColor.risoGreen)
                macroBar(label: "f", value: macros.fatG, target: goal?.fatG, color: SMColor.bronze)
            }
            .frame(maxWidth: compact ? 80 : 110)
        }
    }
}
