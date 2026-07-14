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
        case "recipes_list": return "List recipes"
        case "recipes_get": return "Read recipe"
        case "recipes_save": return "Save recipe"
        case "weeks_get_current": return "Read current week"
        case "weeks_get": return "Read week"
        case "weeks_update_meals": return "Edit week meals"
        case "weeks_apply_ai_draft": return "Plan the whole week"
        case "weeks_regenerate_grocery": return "Regenerate grocery list"
        case "recipes_suggestion_draft": return "Suggest a recipe"
        case "recipes_variation_draft": return "Vary a recipe"
        case "pantry_list": return "Read pantry"
        case "grocery_get": return "Read grocery list"
        case "preferences_get": return "Read preferences"
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

    /// Name of the recipe being saved, extracted from the nested `recipe`
    /// object argument (`recipes_save`). Empty when absent.
    private var recipeSaveName: String {
        guard case .object(let recipe) = call.arguments["recipe"],
              case .string(let name) = recipe["name"], !name.isEmpty
        else { return "" }
        return name
    }

    /// One-line summary of the first meal edit in a `weeks_update_meals`
    /// call: "Recipe → Day Slot", or "Clearing Day Slot" when the slot is
    /// being emptied. Empty when no meals are present.
    private var firstMealEditContext: String {
        guard case .array(let meals) = call.arguments["meals"],
              let first = meals.first,
              case .object(let fields) = first
        else { return "" }
        func field(_ key: String) -> String? {
            guard case .string(let value) = fields[key], !value.isEmpty else { return nil }
            return value
        }
        let recipe = field("recipe_name") ?? ""
        let target = [field("day_name"), field("slot")]
            .compactMap { $0 }
            .joined(separator: " ")
            .capitalized
        if recipe.isEmpty { return target.isEmpty ? "" : "Clearing \(target)" }
        return target.isEmpty ? recipe : "\(recipe) → \(target)"
    }

    /// Short, human-readable context extracted from the tool arguments.
    /// Kept per-tool so each card tells the user what's actually happening
    /// instead of a generic progress label.
    private var argumentContext: String {
        switch call.name {
        case "recipes_list":
            // Optional cuisine filter; tags/include_archived are less readable.
            let cuisine = argValue("cuisine") ?? ""
            return cuisine.isEmpty ? "" : "\(cuisine.capitalized) recipes"
        case "recipes_save":
            // The `recipe` arg is an object; surface its name when present.
            return recipeSaveName
        case "weeks_update_meals":
            // `meals` is an array of (day_name, slot, recipe_name) edits.
            // Summarize the first one — enough to tell the user what's moving.
            return firstMealEditContext
        case "weeks_apply_ai_draft":
            return argValue("prompt") ?? ""
        case "recipes_suggestion_draft":
            return argValue("goal") ?? ""
        case "recipes_variation_draft":
            return argValue("goal") ?? ""
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
        case "recipes_list", "recipes_get": return "book"
        case "recipes_save": return "square.and.pencil"
        case "weeks_get_current", "weeks_get": return "calendar"
        case "weeks_update_meals": return "plus.circle"
        case "weeks_apply_ai_draft": return "sparkles"
        case "weeks_regenerate_grocery": return "arrow.clockwise"
        case "recipes_suggestion_draft": return "wand.and.stars"
        case "recipes_variation_draft": return "arrow.triangle.2.circlepath"
        case "pantry_list": return "leaf"
        case "grocery_get": return "cart"
        case "preferences_get": return "heart"
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
