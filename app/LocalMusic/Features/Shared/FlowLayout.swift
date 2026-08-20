import SwiftUI

/// Lays subviews out left-to-right, wrapping onto as many rows as they need —
/// and claiming no more height than those rows occupy.
///
/// Used by the Models tag bar: a horizontal ScrollView both hid tags off-screen
/// and greedily took vertical space it never used.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    /// Row packing, pure and testable: given item widths and an available
    /// width, the indices that share each row. An item wider than the row is
    /// given a row of its own rather than being dropped.
    static func rows(itemWidths: [CGFloat], maxWidth: CGFloat,
                     spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty && needed > maxWidth {
                rows.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let maxWidth = proposal.width ?? .infinity
        let rows = Self.rows(itemWidths: sizes.map(\.width), maxWidth: maxWidth,
                             spacing: spacing)
        let height = rows.reduce(into: CGFloat.zero) { total, row in
            total += row.map { sizes[$0].height }.max() ?? 0
        } + rowSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map { row in
            row.reduce(into: CGFloat.zero) { $0 += sizes[$1].width }
                + spacing * CGFloat(max(0, row.count - 1))
        }.max() ?? 0
        return CGSize(width: min(maxWidth, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.rows(itemWidths: sizes.map(\.width),
                             maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}
