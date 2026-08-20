import XCTest
import SwiftUI
import AppKit
@testable import LocalMusic

/// The prompt placeholder is an overlay on top of a `TextEditor`, so nothing
/// makes the two agree except arithmetic — and the arithmetic was wrong: the
/// placeholder sat 8 pt below the caret, so the prompt visibly jumped the
/// moment you typed.
///
/// The check draws the editor twice with the *same string* — once as the
/// placeholder, once actually typed — and compares where the ink lands. Same
/// string means glyph shapes and side bearings cancel out, so any difference
/// is pure placement.
@MainActor
final class StudioPromptEditorTests: XCTestCase {
    private struct Harness: View {
        @State var text: String
        var font: Font

        var body: some View {
            StudioPromptEditor(text: $text, font: font)
                .padding(20)
                .frame(width: 820, alignment: .topLeading)
                // Opaque, so "ink" is anything that is not this colour.
                .background(Color.black)
        }
    }

    /// Bounding box of everything drawn over the black background, in pixels.
    private func inkBounds(_ text: String, font: Font) throws -> CGRect {
        // No `NSWindow`: a test that puts windows on the shared `NSApp` can
        // take the whole runner down with it when the last one goes away.
        // `cacheDisplay` only needs a laid-out view.
        let host = NSHostingView(rootView: Harness(text: text, font: font))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                // The faint placeholder grey is well clear of black; the
                // threshold only rejects antialiasing fringe.
                guard color.brightnessComponent > 0.12 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func assertAligned(_ font: Font, _ label: String,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let placeholder = try inkBounds("", font: font)
        let typed = try inkBounds(StudioPromptEditor.placeholder, font: font)

        // A window server is needed to rasterise; skip rather than fail if the
        // typed case drew nothing, which is what a headless run looks like.
        try XCTSkipIf(typed.isNull, "no drawing available (headless?)")
        XCTAssertFalse(placeholder.isNull,
                       "\(label): the placeholder drew nothing", file: file, line: line)

        // One pixel of slack for antialiasing; the bug this pins was 16.
        XCTAssertEqual(placeholder.minY, typed.minY, accuracy: 1,
                       "\(label): placeholder sits \(placeholder.minY - typed.minY) px "
                       + "below the text that replaces it", file: file, line: line)
        XCTAssertEqual(placeholder.minX, typed.minX, accuracy: 1,
                       "\(label): placeholder is indented differently to the "
                       + "text that replaces it", file: file, line: line)
        XCTAssertEqual(placeholder.maxX, typed.maxX, accuracy: 1,
                       "\(label): same string, different width — the placeholder "
                       + "is not being drawn at the editor's font",
                       file: file, line: line)
    }

    /// Simple mode: the 22 pt hero prompt.
    func testPlaceholderSitsWhereTheTypedTextWillHero() throws {
        try assertAligned(Bench.Typo.promptHero, "hero")
    }

    /// Full mode uses a smaller prompt, and a hardcoded inset that happened to
    /// suit one size would drift at the other.
    func testPlaceholderSitsWhereTheTypedTextWillCompact() throws {
        try assertAligned(Bench.Typo.promptCompact, "compact")
    }
}
