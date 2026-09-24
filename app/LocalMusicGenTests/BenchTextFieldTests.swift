// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import XCTest
import SwiftUI
import AppKit
@testable import LocalMusicGen

/// `BenchTextField` draws its own placeholder, because `TextField`'s inherits
/// the field's `foregroundStyle` and came out at nearly full strength — it read
/// as text already typed in rather than as a default waiting to be replaced.
///
/// Drawing it means placing it, and a placeholder that does not sit exactly
/// where the text replacing it will sit makes the field jump on the first
/// keystroke. Same check as the prompt editor's: draw the field twice with the
/// *same string* — once as placeholder, once typed — and compare the ink. Same
/// string means glyph shapes cancel out, so any difference is pure placement.
@MainActor
final class BenchTextFieldTests: XCTestCase {
    private static let sample = "track009"

    private struct Harness: View {
        @State var text: String
        var body: some View {
            BenchTextField(text: $text, placeholder: BenchTextFieldTests.sample)
                .frame(width: 320)
                .padding(16)
                .background(Color.black)
        }
    }

    /// Bounding box of everything drawn over black, in pixels.
    private func inkBounds(_ text: String) throws -> CGRect {
        let host = NSHostingView(rootView: Harness(text: text))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var peak = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // The field's own fill and hairline border are darker than any
                // glyph; this keeps only text.
                guard color.brightnessComponent > 0.30 else { continue }
                peak = max(peak, color.brightnessComponent)
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return .null }
        ink = peak
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Peak brightness of the last `inkBounds` call — how bright the drawn
    /// glyphs actually were.
    private var ink = 0.0

    func testPlaceholderSitsWhereTheTypedTextWill() throws {
        let placeholder = try inkBounds("")
        let typed = try inkBounds(Self.sample)
        try XCTSkipIf(typed.isNull, "no drawing available (headless?)")
        XCTAssertFalse(placeholder.isNull, "the placeholder drew nothing")

        // One pixel of slack for antialiasing.
        XCTAssertEqual(placeholder.minX, typed.minX, accuracy: 1,
                       "placeholder is indented differently to the text that "
                       + "replaces it")
        XCTAssertEqual(placeholder.minY, typed.minY, accuracy: 1,
                       "placeholder sits \(placeholder.minY - typed.minY) px "
                       + "below the text that replaces it")
        // Wider tolerance here, and only here. The placeholder is drawn at a
        // fainter colour on purpose, so its outermost antialiased pixels fall
        // under the ink threshold that the near-white typed glyphs clear:
        // measured, the same string spans 52…175 faint and 51…177 bright. That
        // is the measurement, not the layout — the leading edge and baseline
        // above are what pin the placement, and a wrong font would move this
        // edge by tens of pixels over eight characters, not two.
        XCTAssertEqual(placeholder.maxX, typed.maxX, accuracy: 3,
                       "same string, different width — the placeholder is not "
                       + "drawn at the field's font")
    }

    /// The point of drawing it ourselves: it has to read as a *default*, not as
    /// something already typed. `TextField`'s own placeholder inherited the
    /// field's foreground and came out within a few percent of full strength.
    func testPlaceholderIsVisiblyFainterThanTypedText() throws {
        _ = try inkBounds(Self.sample)
        let typedInk = ink
        _ = try inkBounds("")
        let placeholderInk = ink
        try XCTSkipIf(typedInk == 0, "no drawing available (headless?)")
        XCTAssertLessThan(placeholderInk, typedInk * 0.75,
                          "placeholder \(placeholderInk) vs typed \(typedInk) — "
                          + "too close to read as a default")
    }
}
