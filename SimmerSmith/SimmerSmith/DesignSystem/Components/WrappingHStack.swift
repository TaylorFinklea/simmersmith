import SwiftUI

/// A layout that arranges its children horizontally, wrapping to the next line
/// when the available width is exceeded.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        let totalHeight = rows.enumerated().reduce(CGFloat.zero) { acc, pair in
            let rowHeight = pair.element.map(\.size.height).max() ?? 0
            return acc + rowHeight + (pair.offset > 0 ? spacing : 0)
        }
        let maxWidth = proposal.width ?? .infinity
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX

            for item in row {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }

            y += rowHeight + spacing
        }
    }

    private struct LayoutItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutItem]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = size.width + (rows.last!.isEmpty ? 0 : spacing)

            if currentRowWidth + itemWidth > maxWidth, !rows.last!.isEmpty {
                rows.append([])
                currentRowWidth = 0
            }

            rows[rows.count - 1].append(LayoutItem(subview: subview, size: size))
            currentRowWidth += (rows.last!.count == 1 ? 0 : spacing) + size.width
        }

        return rows.filter { !$0.isEmpty }
    }
}
