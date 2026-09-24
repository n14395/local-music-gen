// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Lays subviews out in a single row, each taking a fixed *share* of the width.
///
/// `HStack` + `.frame(maxWidth: .infinity)` + `.layoutPriority` is the obvious
/// spelling and it is the wrong one. Priority means "satisfy this subview's
/// ideal size first", and an infinite max width makes that ideal the entire
/// row — so the prioritised subview swallowed the width and every other one
/// collapsed to whatever it could not compress away. That is how the render
/// pipeline strip ended up as one wide running stage flanked by bare circles.
/// Shares are declarative instead: every subview keeps its column whatever the
/// others want.
struct WeightedRowLayout: Layout {
    /// One weight per subview, in order. Shorter than the subview count is
    /// fine — the rest count as 1.
    var weights: [CGFloat] = []
    var spacing: CGFloat = 10

    /// Pure and testable: the width each of `count` subviews gets out of
    /// `total`. Weights are normalised, so their absolute scale does not
    /// matter, and a missing or non-positive weight reads as 1 rather than as
    /// a subview that vanishes.
    static func widths(weights: [CGFloat], count: Int, total: CGFloat,
                       spacing: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let resolved = (0..<count).map { index -> CGFloat in
            let weight = index < weights.count ? weights[index] : 1
            return weight > 0 ? weight : 1
        }
        let available = max(0, total - spacing * CGFloat(count - 1))
        let sum = resolved.reduce(0, +)
        return resolved.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let ideal = subviews.reduce(CGFloat.zero) {
            $0 + $1.sizeThatFits(.unspecified).width
        } + gaps
        let total = proposal.width ?? ideal
        let widths = Self.widths(weights: weights, count: subviews.count,
                                 total: total, spacing: spacing)
        // Height comes from measuring each subview at the width it will
        // actually get, not at its ideal — a label that wraps in its column
        // must not be clipped by a row sized for the unwrapped string.
        let height = zip(subviews, widths).reduce(CGFloat.zero) { tallest, pair in
            max(tallest, pair.0.sizeThatFits(
                ProposedViewSize(width: pair.1, height: nil)).height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(weights: weights, count: subviews.count,
                                 total: bounds.width, spacing: spacing)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: widths[index],
                                                     height: bounds.height))
            x += widths[index] + spacing
        }
    }
}
