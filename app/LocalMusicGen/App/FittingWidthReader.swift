// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

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
    /// Bumped by the caller when the content's *shape* changes — a different
    /// screen, a gutter that appeared. See `FittingWidthLayout.updateCache`
    /// for why the layout will not work this out for itself.
    let version: Int
    let onChange: (CGFloat) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        FittingWidthLayout(version: version, onChange: onChange) {
            content()
        }
    }
}

private struct FittingWidthLayout: Layout {
    let version: Int
    let onChange: (CGFloat) -> Void

    /// Wider than any display this app will meet, and the bisection's ceiling.
    /// Content that still overflows here is content with a bug in it, and the
    /// answer stops being useful long before the number does.
    private static let ceiling: CGFloat = 6000
    /// ~1.5 pt of precision over that range, which is finer than anything the
    /// answer is used for.
    private static let steps = 12

    struct Cache {
        var version: Int?
        var height: CGFloat?
        var fitting: CGFloat?
        /// The last answer, kept *across* invalidations as a starting guess —
        /// see `fittingWidth(of:height:hint:)`. Not an answer to reuse: it
        /// survives precisely so the next real measurement can be cheap.
        var hint: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Deliberately keeps the answer.
    ///
    /// SwiftUI hands this layout fresh subviews whenever the content
    /// re-renders, which is most of the calls and almost never a change of
    /// shape. Dropping the answer for those meant every ordinary rebuild of
    /// the screen already on show re-measured the whole window — two probes
    /// against a warm hint, the full twelve-step bisection against a cold
    /// one. `version` is how the shell says the shape really did change.
    ///
    /// What it costs to be wrong is worth stating, because it is what makes
    /// this safe: the number does not lay anything out. It feeds
    /// `refitSidebar`, which decides whether the sidebar auto-collapses. A
    /// stale answer delays that decision until the next screen change or
    /// window resize. Nothing clips, and nothing is mispositioned.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Cache) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        // Memoised on height: the bisection is a dozen measuring passes over
        // the whole screen, and a resize drags the layout through many.
        if cache.version != version || cache.height != proposal.height {
            let fitting = Self.fittingWidth(of: subview,
                                            height: proposal.height,
                                            hint: cache.hint)
            cache.version = version
            cache.height = proposal.height
            cache.hint = fitting
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
    ///
    /// `hint` is the previous answer, if there is one. Screens are measured
    /// again on every rebuild, and the overwhelmingly common outcome is the
    /// number they gave last time — a rebuild is usually a value changing
    /// inside a layout whose shape did not. Two probes confirm that, against
    /// the fourteen a cold bisection costs; anything else falls through to the
    /// full search, so the answer is never the hint's word for it.
    private static func fittingWidth(of subview: LayoutSubview,
                                     height: CGFloat?,
                                     hint: CGFloat? = nil) -> CGFloat {
        func fits(_ width: CGFloat) -> Bool {
            subview.sizeThatFits(
                ProposedViewSize(width: width, height: height)).width
                <= width + 0.5
        }
        // Almost everything fits at nothing at all, by truncating. Answering
        // that in one call keeps the common case free.
        if fits(0) { return 0 }

        // The bisection's own resolution, so confirming the hint can never
        // return a width a cold run would have disagreed with.
        let grain = ceiling / pow(2, CGFloat(steps))
        if let hint, hint > grain, hint < ceiling,
           fits(hint), !fits(hint - grain) {
            return hint
        }

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
