// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import LocalMusicGen

/// Measuring the width a screen needs in order not to be clipped.
///
/// The first attempt asked SwiftUI for the content's *minimum* size and the
/// window still stopped short, because a minimum is the width at which layout
/// stops shrinking — and most things shrink to nothing by truncating. Probed
/// at a width-0 proposal: `Text` reports 0, five buttons report 82, a
/// `GeometryReader` around a 316 pt rail reports 0. None of that is what gets
/// clipped. What gets clipped is content that *ignores* the offer, and these
/// tests are about finding that instead.
@MainActor
final class FittingWidthReaderTests: XCTestCase {
    private func measure<V: View>(
        at width: CGFloat,
        @ViewBuilder _ content: @escaping () -> V) -> CGFloat? {
        var reported: CGFloat?
        let view = FittingWidthReader(version: 0,
                                      onChange: { reported = $0 },
                                      content: content)
        let host = NSHostingView(rootView: view.frame(width: width, height: 400))
        host.layoutSubtreeIfNeeded()
        // `onChange` is handed off the layout pass on purpose.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return reported
    }

    /// A fixed rail beside a panel with a floor — the shape that overflows.
    func testItFindsWhatRefusesToShrink() {
        let reported = measure(at: 400) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 316)
                Color.clear.frame(minWidth: 468)
            }
        }
        XCTAssertEqual(try XCTUnwrap(reported), 784, accuracy: 2)
    }

    /// The regression that made the first attempt useless. Text is never
    /// clipped — it truncates — so it must ask for nothing, or every screen
    /// would demand the width of its longest sentence.
    func testTextAsksForNothingBecauseItTruncates() {
        let reported = measure(at: 300) {
            Text("Every edit is stored as a list and re-run from the untouched "
                 + "original, so you can change your mind later")
        }
        XCTAssertEqual(try XCTUnwrap(reported), 0, accuracy: 2)
    }

    /// Buttons compress their labels rather than overflow, so a crowded
    /// toolbar is not by itself a reason to widen the window.
    func testAToolbarOfButtonsDoesNotDemandItsIdealWidth() {
        let reported = measure(at: 300) {
            HStack { ForEach(0..<5, id: \.self) { i in Button("Fade in \(i)") {} } }
        }
        XCTAssertLessThan(try XCTUnwrap(reported), 300)
    }

    /// The measurement must see through the containers a screen is built from.
    /// A `GeometryReader` reports a minimum of zero however wide its contents
    /// are — the old question could not see this at all.
    func testItSeesThroughAGeometryReader() {
        let reported = measure(at: 400) {
            GeometryReader { _ in Color.clear.frame(width: 316) }
        }
        // A GeometryReader takes what it is given and clips inside itself, so
        // it genuinely does not overflow. Pinned so a later change here is a
        // decision rather than a surprise.
        XCTAssertEqual(try XCTUnwrap(reported), 0, accuracy: 2)
    }

    /// Answering must not depend on how much room there happens to be, or the
    /// window would chase its own resize.
    func testTheAnswerDoesNotDependOnTheWidthOffered() {
        func editorish() -> some View {
            HStack(spacing: 0) {
                Color.clear.frame(minWidth: 468)
                Color.clear.frame(width: 316)
            }
        }
        let wide = measure(at: 2400) { editorish() }
        let narrow = measure(at: 500) { editorish() }
        XCTAssertEqual(try XCTUnwrap(wide), try XCTUnwrap(narrow), accuracy: 2)
    }

    /// Fully flexible content asks for nothing, so an ordinary screen never
    /// pins the window open.
    func testFlexibleContentAsksForNothing() {
        let reported = measure(at: 1200) { Color.clear.frame(maxWidth: .infinity) }
        XCTAssertEqual(try XCTUnwrap(reported), 0, accuracy: 2)
    }

    /// Wrapping a view must not change how it lays out.
    func testItDoesNotDisturbWhatItMeasures() {
        let plain = NSHostingView(rootView: Color.clear
            .frame(minWidth: 468, maxWidth: .infinity, minHeight: 400)
            .frame(width: 1200))
        plain.layoutSubtreeIfNeeded()
        let wrapped = NSHostingView(rootView: FittingWidthReader(version: 0, onChange: { _ in }) {
            Color.clear.frame(minWidth: 468, maxWidth: .infinity, minHeight: 400)
        }.frame(width: 1200))
        wrapped.layoutSubtreeIfNeeded()
        XCTAssertEqual(wrapped.fittingSize.width, plain.fittingSize.width,
                       accuracy: 1)
        XCTAssertEqual(wrapped.fittingSize.height, plain.fittingSize.height,
                       accuracy: 1)
    }
}
