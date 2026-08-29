import AppKit
import SwiftUI

/// How wide to make the window, given how wide it is and how wide the screen
/// inside it needs to be.
///
/// Pure, so the two rules that matter can be tested without a window: never
/// take width away from someone who chose it, and never grow off the display.
enum WindowGrowth {
    /// The frame width to resize to, or nil to leave the window alone.
    static func target(current: CGFloat, required: CGFloat,
                       screenLimit: CGFloat) -> CGFloat? {
        let wanted = min(required, screenLimit)
        // One guard, doing two jobs, which is why it is written as "wider than
        // it already is" rather than as "needs more than it has":
        //
        //  - Growing only. A window that also shrank whenever the screen
        //    inside it needed less would undo every deliberate drag of a
        //    corner — unpinning the queue would quietly take 340 pt off a
        //    window widened on purpose.
        //  - It settles. Once clamped to a display it cannot outgrow, the
        //    answer is nil rather than the same resize attempted again on
        //    every layout pass for as long as the window stays too small.
        guard wanted > current + 0.5 else { return nil }
        return wanted
    }

    /// Where the widened window should start, so it stays on the display.
    /// Growing to the right walks a window that was near the right edge off
    /// the end of it.
    static func originX(current: CGFloat, width: CGFloat,
                        screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat {
        let rightmost = max(screenMinX, screenMaxX - width)
        return min(max(current, screenMinX), rightmost)
    }
}

/// Widens the window when the screen inside it needs more room than it has.
///
/// `.frame(minWidth:)` sets `NSWindow.contentMinSize`, which stops the user
/// dragging the window narrower and does nothing whatever to a window that is
/// *already* narrower than the new floor. Measured, on a 600 pt window: raising
/// `contentMinSize` from 200 to 1000 leaves it at 600. Pinning the queue raises
/// the requirement by 340 pt mid-session, so without this the rail simply took
/// its column out of the screen it was supposed to sit beside.
///
/// A representable rather than `NSApp.keyWindow`: this has to be *this*
/// window, and it has to work before the window is key.
struct WindowWidthFloor: NSViewRepresentable {
    /// The content width the window has to be able to show.
    let width: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred a turn: the view has no window yet during `make`, and
        // resizing from inside an update re-enters the layout that asked for
        // it.
        DispatchQueue.main.async { grow(around: view) }
        return view
    }

    /// `updateNSView` runs on every pass of the view above it, and the width
    /// it is given is the same number on nearly all of them — so this used to
    /// schedule a main-queue block per render to discover there was nothing to
    /// do. The coordinator remembers what was last asked for, and only a new
    /// requirement reaches the window.
    ///
    /// Deliberately not "only when it would grow": whether it grows depends on
    /// the window's current frame, which the user can drag at any time, so
    /// that test belongs where it already is, in `WindowGrowth.target`.
    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastRequested != width else { return }
        context.coordinator.lastRequested = width
        DispatchQueue.main.async { grow(around: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastRequested: CGFloat?
    }

    private func grow(around view: NSView) {
        guard let window = view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        // Asked of the window rather than assumed: the chrome around a content
        // width is zero for this window's style and would not be for others.
        let required = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: width, height: 0)).width
        guard let target = WindowGrowth.target(
            current: window.frame.width, required: required,
            screenLimit: screen.visibleFrame.width) else { return }

        var frame = window.frame
        frame.size.width = target
        frame.origin.x = WindowGrowth.originX(
            current: frame.origin.x, width: target,
            screenMinX: screen.visibleFrame.minX,
            screenMaxX: screen.visibleFrame.maxX)
        NSAnimationContext.runAnimationGroup { context in
            // The same 0.22 the panels move on, and through `animator()` rather
            // than `setFrame(_:display:animate:)` — that one spins its own
            // runloop and blocks everything else while it does.
            context.duration = 0.22
            window.animator().setFrame(frame, display: true)
        }
    }
}
