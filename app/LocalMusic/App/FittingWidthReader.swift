import SwiftUI

/// Reports the narrowest width at which its content stops overflowing.
///
/// Deliberately **not** "what is the content's minimum size". That was the
/// first answer here and it was the wrong question: SwiftUI reports a minimum
/// of zero for anything that survives being squeezed by truncating, which is
/// most of a screen. Measured, with a width-0 proposal:
///
///     Text (with or without lineLimit) ....  0
///     an HStack of five buttons ...........  82
///     a GeometryReader around a 316 pt rail   0
///     a plain 316 pt frame ................ 316
///
/// Meanwhile the thing that actually goes wrong — a fixed-width rail drawing
/// outside the window and being clipped at both edges — comes from views that
/// *ignore* the proposal. A minimum of zero says nothing about them.
///
/// So this asks the question that matches the symptom. Offered `w`, does the
/// content take more than `w`? That is precisely "is it clipped", and the
/// narrowest `w` where the answer is no is the width the window needs. Found
/// by bisection rather than by asking, because SwiftUI has no call that
/// returns it.
struct FittingWidthReader<Content: View>: View {
    let onChange: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        FittingWidthLayout(onChange: onChange) {
            content()
        }
    }
}

private struct FittingWidthLayout: Layout {
    let onChange: (CGFloat) -> Void

    /// Wider than any display this app will meet, and the bisection's ceiling.
    /// Content that still overflows here is content with a bug in it, and the
    /// answer stops being useful long before the number does.
    private static let ceiling: CGFloat = 6000
    /// ~1.5 pt of precision over that range, which is finer than anything the
    /// answer is used for.
    private static let steps = 12

    struct Cache {
        var height: CGFloat?
        var fitting: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Subviews changing means a different screen, and a different answer.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Cache) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        // Memoised on height: the bisection is a dozen measuring passes over
        // the whole screen, and a resize drags the layout through many.
        if cache.height != proposal.height {
            let fitting = Self.fittingWidth(of: subview, height: proposal.height)
            cache.height = proposal.height
            if cache.fitting != fitting {
                cache.fitting = fitting
                // Off this layout pass: touching observable state inside one
                // is the "modifying state during view update" trap, and this
                // value moves a window.
                DispatchQueue.main.async { onChange(fitting) }
            }
        }
        return subview.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin,
                              proposal: ProposedViewSize(bounds.size))
    }

    /// The narrowest offer the content does not exceed.
    ///
    /// Monotone in the offer — squeezing a layout never makes it want *less*
    /// room — which is what makes bisection valid and what stops the window
    /// growing round in a circle.
    private static func fittingWidth(of subview: LayoutSubview,
                                     height: CGFloat?) -> CGFloat {
        func fits(_ width: CGFloat) -> Bool {
            subview.sizeThatFits(
                ProposedViewSize(width: width, height: height)).width
                <= width + 0.5
        }
        // Almost everything fits at nothing at all, by truncating. Answering
        // that in one call keeps the common case free.
        if fits(0) { return 0 }
        // Nothing fits even here: report the ceiling rather than bisect
        // towards an answer that does not exist.
        guard fits(ceiling) else { return ceiling }

        var low: CGFloat = 0
        var high = ceiling
        for _ in 0..<steps {
            let mid = (low + high) / 2
            if fits(mid) { high = mid } else { low = mid }
        }
        return high
    }
}
