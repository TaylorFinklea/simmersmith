import SwiftUI
import SimmerSmithKit

struct AssistantToolCallCard: View {
    let call: AssistantToolCall

    var body: some View {
        HStack(alignment: .top, spacing: SMSpacing.md) {
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 28, height: 28)
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textPrimary)
                Text(subtitle)
                    .font(SMFont.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(3)
            }
            Spacer(minLength: SMSpacing.sm)

            if call.status == "running" {
                ProgressView().controlSize(.small)
            }
        }
        .padding(SMSpacing.md)
        .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    private var displayTitle: String {
        switch call.name {
        case "get_current_week": return "Read current week"
        case "get_dietary_goal": return "Read dietary goal"
        case "generate_week_plan": return "Plan the whole week"
        case "add_meal": return "Add meal"
        case "swap_meal": return "Swap meal"
        case "remove_meal": return "Remove meal"
        case "set_meal_approved": return "Approve meal"
        case "rebalance_day": return "Rebalance a day"
        case "fetch_pricing": return "Fetch Kroger prices"
        case "set_dietary_goal": return "Set dietary goal"
        default: return call.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var subtitle: String {
        if !call.detail.isEmpty { return call.detail }
        if call.status == "running" { return "Running…" }
        return call.ok ? "Done" : "Failed"
    }

    private var subtitleColor: Color {
        if call.status == "running" { return SMColor.textSecondary }
        if !call.ok { return SMColor.destructive }
        return SMColor.textSecondary
    }

    private var strokeColor: Color {
        if call.status == "running" { return SMColor.primary.opacity(0.4) }
        if !call.ok { return SMColor.destructive.opacity(0.5) }
        return SMColor.divider
    }

    private var iconName: String {
        switch call.name {
        case "generate_week_plan", "rebalance_day": return "sparkles"
        case "add_meal": return "plus.circle"
        case "swap_meal": return "arrow.triangle.2.circlepath"
        case "remove_meal": return "minus.circle"
        case "set_meal_approved": return "checkmark.circle"
        case "fetch_pricing": return "cart"
        case "set_dietary_goal": return "target"
        case "get_current_week", "get_dietary_goal": return "eye"
        default: return "wand.and.stars"
        }
    }

    private var iconTint: Color {
        if call.status == "running" { return SMColor.primary }
        if !call.ok { return SMColor.destructive }
        return SMColor.primary
    }

    private var iconBackground: Color {
        if !call.ok { return SMColor.destructive.opacity(0.15) }
        return SMColor.primary.opacity(0.18)
    }
}
