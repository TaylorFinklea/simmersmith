import SwiftUI
import SimmerSmithKit

/// Compact horizontal meal row — used in week-roster scrollers and
/// in the small "today's other slots" stack. Caveat slot label,
/// italic-serif recipe name, ember check on approved.
struct CompactMealCard: View {
    let meal: WeekMeal
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: SMSpacing.md) {
                Text(meal.slot.lowercased())
                    .font(SMFont.handwritten(13))
                    .foregroundStyle(SMColor.inkSoft)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 80, alignment: .leading)

                VStack(alignment: .leading, spacing: SMSpacing.xs) {
                    Text(meal.recipeName)
                        .font(SMFont.serifTitle(15))
                        .foregroundStyle(SMColor.ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !meal.sides.isEmpty {
                        SideChipRow(sides: meal.sides)
                    }
                }

                if meal.approved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(SMColor.ember)
                }
            }
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.sm)
            .background(SMColor.paperAlt)
            .overlay(
                Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Read-only pill row for a meal's sides — read-only here because the
/// whole card is a single Button (nesting tap targets is awkward in
/// SwiftUI). Editing happens via the meal action sheet → "Manage sides".
struct SideChipRow: View {
    let sides: [WeekMealSide]

    var body: some View {
        FlowLayout(spacing: SMSpacing.xs) {
            ForEach(sides) { side in
                Text(side.name.lowercased())
                    .font(SMFont.handwritten(12))
                    .foregroundStyle(SMColor.inkSoft)
                    .padding(.horizontal, SMSpacing.sm)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(SMColor.rule, lineWidth: 0.6)
                    )
            }
        }
    }
}

/// Minimal flow layout — wraps chips onto multiple lines instead of
/// truncating. Avoids pulling in a third-party flow lib for one usage.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + (lineWidth > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
