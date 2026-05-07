import SwiftUI
import SimmerSmithKit

/// Build 62 — Fusion-styled action sheet for tapping a meal on the
/// Week tab. Replaces the previous `.confirmationDialog` so the menu
/// reads like the rest of the redesign: paper background, washi-
/// taped title plate, action rows with SF Symbol + Spectral label +
/// hand-drawn rules between groups. Native sheet chrome (drag
/// indicator, swipe-down dismiss) is preserved.
///
/// Ownership note: this view owns no model state. Every action is
/// reflected back through the closure callbacks so the parent
/// (`WeekView`) keeps doing the actual work.
struct MealActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let meal: WeekMeal

    var onViewRecipe: (() -> Void)?
    var onRate: (() -> Void)?
    var onEditName: () -> Void
    var onEditNotes: () -> Void
    var onManageSides: () -> Void
    var onMove: () -> Void
    var onLinkRecipe: (() -> Void)?
    var onCreateWithAI: (() -> Void)?
    var onToggleApproval: () -> Void
    var onMarkEatingOut: () -> Void
    var onSaveLeftovers: () -> Void
    var onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                titlePlate
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.top, SMSpacing.lg)
                    .padding(.bottom, SMSpacing.md)

                // Section 1 — Recipe (linked recipe only)
                if meal.recipeId != nil {
                    actionGroup {
                        actionRow(icon: "book.pages", label: "view recipe", role: .primary) {
                            onViewRecipe?()
                            dismiss()
                        }
                        actionRow(icon: "star", label: "rate this meal", role: .normal) {
                            onRate?()
                            dismiss()
                        }
                    }
                }

                // Section 2 — Edit (always)
                actionGroup {
                    actionRow(icon: "pencil", label: "edit name", role: .normal) {
                        onEditName()
                        dismiss()
                    }
                    actionRow(icon: "text.alignleft", label: "edit notes", role: .normal) {
                        onEditNotes()
                        dismiss()
                    }
                    actionRow(icon: "fork.knife", label: "manage sides", role: .normal) {
                        onManageSides()
                        dismiss()
                    }
                }

                // Section 3 — Move / Link (linking only when no recipe is linked)
                actionGroup {
                    actionRow(icon: "arrow.up.and.down.and.arrow.left.and.right", label: "move to…", role: .normal) {
                        onMove()
                        dismiss()
                    }
                    if meal.recipeId == nil {
                        actionRow(icon: "link", label: "link to a recipe", role: .normal) {
                            onLinkRecipe?()
                            dismiss()
                        }
                        actionRow(icon: "sparkles", label: "create recipe with the smith", role: .primary) {
                            onCreateWithAI?()
                            dismiss()
                        }
                    }
                }

                // Section 4 — Status
                actionGroup {
                    actionRow(
                        icon: meal.approved ? "checkmark.seal.fill" : "checkmark.seal",
                        label: meal.approved ? "unapprove" : "approve",
                        role: .normal
                    ) {
                        onToggleApproval()
                        dismiss()
                    }
                    actionRow(icon: "fork.knife.circle", label: "ate out tonight", role: .normal) {
                        onMarkEatingOut()
                        dismiss()
                    }
                    actionRow(icon: "snowflake", label: "save leftovers to freezer", role: .normal) {
                        onSaveLeftovers()
                        dismiss()
                    }
                }

                // Section 5 — Destructive
                actionGroup(isLast: true) {
                    actionRow(icon: "trash", label: "remove", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
            }
            .padding(.bottom, SMSpacing.xl)
        }
        .paperBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Title plate
    //
    // A small index-card-style plate at the top with washi tape, the
    // meal slot eyebrow, and the meal name in italic Instrument Serif.
    // This anchors the sheet visually so the user knows which meal
    // they're acting on without reading the toolbar.

    private var titlePlate: some View {
        FuIndexCard(rotation: -0.4, washi: SMColor.risoYellow, rivets: false) {
            VStack(alignment: .leading, spacing: 6) {
                FuEyebrow(text: meal.dayName.lowercased() + " · " + meal.slot.lowercased())
                Text(meal.recipeName)
                    .font(SMFont.serifDisplay(24))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if meal.approved {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("done")
                            .font(SMFont.handwritten(13))
                    }
                    .foregroundStyle(SMColor.ember)
                }
            }
        }
    }

    // MARK: - Action group + row primitives

    private enum ActionRole {
        case normal
        case primary       // ember treatment for "do this" actions
        case destructive   // red treatment for delete

        var iconTint: Color {
            switch self {
            case .normal:      return SMColor.inkSoft
            case .primary:     return SMColor.ember
            case .destructive: return SMColor.destructive
            }
        }

        var textTint: Color {
            switch self {
            case .normal:      return SMColor.ink
            case .primary:     return SMColor.ink
            case .destructive: return SMColor.destructive
            }
        }
    }

    @ViewBuilder
    private func actionGroup<Content: View>(
        isLast: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, SMSpacing.lg)
        if !isLast {
            HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                .padding(.horizontal, SMSpacing.lg)
                .padding(.vertical, SMSpacing.sm)
        }
    }

    private func actionRow(
        icon: String,
        label: String,
        role: ActionRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: SMSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(role.iconTint)
                    .frame(width: 24, alignment: .leading)
                Text(label)
                    .font(SMFont.bodySerif(16))
                    .foregroundStyle(role.textTint)
                Spacer()
                if role == .primary {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SMColor.ember)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

