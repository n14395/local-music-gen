import XCTest
@testable import LocalMusicGen

/// The message the sidebar shows when the engine will not stay up.
///
/// Written after a real investigation stalled on it: the engine had been dying
/// on a dyld failure it printed on its way out, and the message said only
/// "check the logs" — pointing at a file the restart had just truncated.
final class BackendCrashReasonTests: XCTestCase {
    func testKeepsTheAdviceWhenTheEngineSaidNothing() {
        XCTAssertEqual(BackendProcessManager.repeatedCrashReason(lastLine: nil),
                       "The engine crashed repeatedly. Check the logs.")
        XCTAssertEqual(BackendProcessManager.repeatedCrashReason(lastLine: "   "),
                       "The engine crashed repeatedly. Check the logs.")
    }

    func testCarriesTheLastLineWhenThereIsOne() {
        let reason = BackendProcessManager.repeatedCrashReason(
            lastLine: "dyld: Library not loaded: @rpath/libggml.0.dylib")
        XCTAssertEqual(reason, "The engine crashed repeatedly. Last output: "
                       + "dyld: Library not loaded: @rpath/libggml.0.dylib")
    }

    func testTrimsSurroundingWhitespace() {
        let reason = BackendProcessManager.repeatedCrashReason(
            lastLine: "\n  ace-lm failed (exit -6)  \n")
        XCTAssertEqual(reason, "The engine crashed repeatedly. "
                       + "Last output: ace-lm failed (exit -6)")
    }

    /// This lands in a sidebar, not a terminal — a worker traceback's last
    /// line can be a paragraph.
    func testClipsALongLine() {
        let long = String(repeating: "x", count: 400)
        let reason = BackendProcessManager.repeatedCrashReason(lastLine: long)
        XCTAssertTrue(reason.hasSuffix("\u{2026}"))
        XCTAssertEqual(reason.count, "The engine crashed repeatedly. Last output: ".count + 160)
    }

    func testKeepsALineExactlyAtTheLimitWhole() {
        let line = String(repeating: "y", count: 160)
        let reason = BackendProcessManager.repeatedCrashReason(lastLine: line)
        XCTAssertTrue(reason.hasSuffix(line))
        XCTAssertFalse(reason.contains("\u{2026}"))
    }
}
