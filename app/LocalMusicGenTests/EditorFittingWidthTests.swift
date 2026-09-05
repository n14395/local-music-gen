import AppKit
import SwiftUI
import XCTest
@testable import LocalMusicGen

/// The Editor is the screen that broke two attempts at sizing this window, so
/// it is measured directly rather than through a stand-in.
///
/// It is the widest screen in the app by a distance: a fixed 316 pt rail, a
/// 468 pt panel beside it, and a title row carrying a name, three badges, a
/// stats line and four buttons. Twice the window was sized from a number that
/// did not come from here, and twice the screen overflowed its own edges and
/// was clipped left and right.
@MainActor
final class EditorFittingWidthTests: XCTestCase {
    /// The screen is built by handing the store its material directly rather
    /// than by `open(songId:)`.
    ///
    /// Two reasons, both learned the hard way. `open` resolves the file
    /// through `StoragePaths.libraryAudio` — the user's *real* Library folder,
    /// with no override — so the fixture was writing stray takes into an
    /// actual music library. And it loads the audio into a live
    /// `AVAudioEngine` with metering on, which then contends with
    /// `MultiPartPlayerTests` and fails a metering test that passes on its
    /// own. Neither has anything to do with how wide the screen lays out.
    private func editorShowingATrack() throws -> AppEnvironment {
        let env = AppEnvironment(database: try DatabaseManager.inMemory())
        env.editor.material = EditorStore.Material(
            id: "fit", ownerType: "song", title: "track017",
            songTitle: nil, stemKind: nil,
            promptLine: "Japanese female vocals over a slow lo-fi beat",
            fileURL: URL(fileURLWithPath: "/dev/null"),
            backupURL: URL(fileURLWithPath: "/dev/null"),
            fileName: "fit.wav",
            waveformCacheURL: URL(fileURLWithPath: "/dev/null"),
            sampleRate: 48000, fileDurationS: 300, origin: .generated)
        return env
    }

    /// What the Editor actually needs, measured through the same reader the
    /// window is sized from.
    private func fittingWidth(of env: AppEnvironment,
                              offered: CGFloat) -> CGFloat? {
        var reported: CGFloat?
        let screen = EditorScreen(store: env.editor, catalog: env.catalog,
                                  library: env.library, parts: env.partsStore,
                                  jobs: env.jobsStore, playback: env.playback)
        let view = FittingWidthReader(version: 0, onChange: { reported = $0 }) { screen }
        let host = NSHostingView(rootView: view.frame(width: offered, height: 900))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return reported
    }

    func testTheEditorAsksForMoreThanTheOldConstantAllowed() throws {
        let env = try editorShowingATrack()
        XCTAssertNotNil(env.editor.material, "the screen under test must be the "
                        + "real workspace, not the empty state")

        let needed = try XCTUnwrap(fittingWidth(of: env, offered: 900))

        // The measurement that matters, and the one both earlier attempts got
        // wrong. Measured at ~1096 pt: with the 230 pt sidebar beside it the
        // window has to be ~1326, where the old constant put it at 1100 — the
        // ~226 pt that was being clipped off the edges.
        XCTAssertGreaterThan(needed, SidebarFit.contentMinWidth,
                             "the Editor needs more than the constant the "
                             + "window used to be sized from — that gap is the "
                             + "bug this measurement exists to close")
        XCTAssertEqual(needed, 1096, accuracy: 60)
        XCTAssertLessThan(needed, 6000, "and must not hit the bisection ceiling")
    }

    /// The answer cannot move with the window, or the resize chases itself.
    func testTheEditorsRequirementIsStable() throws {
        let env = try editorShowingATrack()
        let narrow = try XCTUnwrap(fittingWidth(of: env, offered: 700))
        let wide = try XCTUnwrap(fittingWidth(of: env, offered: 2400))
        XCTAssertEqual(narrow, wide, accuracy: 2)
    }
}
