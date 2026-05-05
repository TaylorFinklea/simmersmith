import SwiftUI
import SimmerSmithKit

struct AssistantToolCallCard: View {
    let call: AssistantToolCall
    /// Optional handlers for the Was→Becomes diff card (M26 Phase 5).
    /// When `call.proposedChange` is non-nil and these are wired by
    /// the parent view, the card renders Confirm/Cancel buttons that
    /// send follow-up messages to the assistant.
    var onConfirmProposedChange: ((AssistantProposedChange) -> Void)? = nil
    var onCancelProposedChange: ((AssistantProposedChange) -> Void)? = nil

    var body: some View {
        if let proposed = call.proposedChange {
            ProposedChangeCard(
                proposal: proposed,
                onConfirm: onConfirmProposedChange,
                onCancel: onCancelProposedChange
            )
        } else {
            defaultCard
        }
    }

    private var defaultCard: some View {
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
        case "get_preferences_summary": return "Read preferences"
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
        // Prefer server-provided detail when we have it — that's the
        // authoritative post-tool summary. While running, fall back to an
        // argument-derived context string so the user sees what's being
        // done instead of a generic "Running…".
        if !call.detail.isEmpty { return call.detail }
        if call.status == "running" {
            let context = argumentContext
            return context.isEmpty ? "Running…" : context
        }
        return call.ok ? "Done" : "Failed"
    }

    private func argValue(_ key: String) -> String? {
        guard let value = call.arguments[key] else { return nil }
        let text = value.stringDescription
        return text.isEmpty ? nil : text
    }

    /// Short, human-readable context extracted from the tool arguments.
    /// Kept per-tool so each card tells the user what's actually happening
    /// instead of a generic progress label.
    private var argumentContext: String {
        switch call.name {
        case "swap_meal":
            // `swap_meal` carries either (day+slot) or meal_id plus the new
            // recipe name. Day/slot is friendlier than a UUID.
            let target = [argValue("day_name"), argValue("slot")]
                .compactMap { $0 }
                .joined(separator: " ")
            let recipe = argValue("recipe_name") ?? ""
            if !recipe.isEmpty && !target.isEmpty {
                return "\(recipe) · \(target.capitalized)"
            }
            return recipe.isEmpty ? target.capitalized : recipe
        case "add_meal":
            let target = [argValue("day_name"), argValue("slot")]
                .compactMap { $0 }
                .joined(separator: " ")
            let recipe = argValue("recipe_name") ?? ""
            if !recipe.isEmpty && !target.isEmpty {
                return "\(recipe) → \(target.capitalized)"
            }
            return recipe.isEmpty ? target.capitalized : recipe
        case "remove_meal":
            return [argValue("day_name"), argValue("slot")]
                .compactMap { $0 }
                .joined(separator: " ")
                .capitalized
        case "rebalance_day":
            return argValue("day_name")?.capitalized ?? ""
        case "set_meal_approved":
            let approved = argValue("approved") ?? ""
            return approved.contains("true") ? "Marking as approved" : "Marking as not approved"
        case "set_dietary_goal":
            let type = argValue("goal_type") ?? ""
            let kcal = argValue("daily_calories") ?? ""
            return [type.capitalized, kcal.isEmpty ? "" : "\(kcal) kcal"]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case "fetch_pricing":
            return "Getting current store prices"
        case "generate_week_plan":
            return "Building 21 meals"
        default:
            return ""
        }
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

/// M26 Phase 5 — Was→Becomes diff card for assistant-proposed
/// changes (currently only `swap_meal`). Tap Confirm to apply, Cancel
/// to abandon. The parent view sends a follow-up assistant message
/// so the LLM dispatches `confirm_swap_meal` / `cancel_swap_meal`.
struct ProposedChangeCard: View {
    let proposal: AssistantProposedChange
    let onConfirm: ((AssistantProposedChange) -> Void)?
    let onCancel: ((AssistantProposedChange) -> Void)?

    @State private var resolved: Resolution? = nil

    enum Resolution { case confirmed, cancelled }

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            HStack(spacing: SMSpacing.sm) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(SMColor.primary)
                Text(proposal.summary)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
            }

            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                diffRow(label: "Was", value: proposal.beforeRecipeName, color: SMColor.textSecondary)
                diffRow(label: "Becomes", value: proposal.afterRecipeName, color: SMColor.textPrimary, bold: true)
            }
            .padding(.vertical, SMSpacing.sm)
            .padding(.horizontal, SMSpacing.md)
            .background(SMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: SMRadius.sm))

            if let resolved {
                Text(resolved == .confirmed ? "Applied — the assistant will finalize." : "Cancelled — no changes were made.")
                    .font(SMFont.caption)
                    .foregroundStyle(resolved == .confirmed ? SMColor.success : SMColor.textTertiary)
            } else {
                HStack(spacing: SMSpacing.md) {
                    Button {
                        resolved = .cancelled
                        onCancel?(proposal)
                    } label: {
                        Text("Cancel")
                            .font(SMFont.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.sm)
                            .background(SMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: SMRadius.sm))
                    }
                    .buttonStyle(.plain)

                    Button {
                        resolved = .confirmed
                        onConfirm?(proposal)
                    } label: {
                        Text("Confirm")
                            .font(SMFont.label)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.sm)
                            .background(SMColor.primary, in: RoundedRectangle(cornerRadius: SMRadius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(SMSpacing.md)
        .background(SMColor.surfaceCard, in: RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .stroke(SMColor.primary.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func diffRow(label: String, value: String, color: Color, bold: Bool = false) -> some View {
        HStack(alignment: .top, spacing: SMSpacing.sm) {
            Text(label)
                .font(SMFont.caption)
                .foregroundStyle(SMColor.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(bold ? SMFont.subheadline : SMFont.body)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
