import AppKit
import SwiftUI
import XCTest
@testable import LocalMusic

/// When the sidebar gets a column, and who decides.
///
/// The window overrules the preference and must not erase it: dragging a
/// corner in and out again has to leave the sidebar where the user put it, not
/// where the drag left it.
final class SidebarFitTests: XCTestCase {
    private let sidebar = Bench.Metrics.sidebarWidth   // 230
    private let content = SidebarFit.contentMinWidth   // 870

    // MARK: - The arithmetic

    func testBothFitWhenThereIsRoomForBoth() {
        XCTAssertTrue(SidebarFit.fits(windowWidth: content + sidebar, contentMinWidth: content))
        XCTAssertTrue(SidebarFit.fits(windowWidth: content + sidebar + 200, contentMinWidth: content))
    }

    /// One point under is under.
    func testOnePointShortDoesNotFit() {
        XCTAssertFalse(SidebarFit.fits(windowWidth: content + sidebar - 1, contentMinWidth: content))
    }

    /// The pinned queue is padding *inside* the measured screen, so it arrives
    /// as a larger content minimum rather than as a term of its own.
    func testAWiderScreenRequirementCrowdsTheSidebarOut() {
        let width = content + sidebar + 100
        XCTAssertTrue(SidebarFit.fits(windowWidth: width,
                                      contentMinWidth: content + 100))
        XCTAssertFalse(SidebarFit.fits(windowWidth: width,
                                       contentMinWidth: content + 101))
    }

    /// The first layout pass has measured nothing. Answering "does not fit"
    /// there would collapse the sidebar and snap it back open in the opening
    /// frame of every launch.
    func testAnUnmeasuredWidthIsNotTreatedAsCramped() {
        XCTAssertTrue(SidebarFit.fits(windowWidth: 0, contentMinWidth: content))
    }

    /// The floor the window is given has to be one the sidebar can survive
    /// being removed from — otherwise the collapse can never happen and the
    /// feature is decoration.
    func testTheWindowFloorIsNarrowerThanBothTogether() {
        XCTAssertLessThan(SidebarFit.contentMinWidth,
                          SidebarFit.contentMinWidth + sidebar)
        XCTAssertFalse(SidebarFit.fits(windowWidth: content, contentMinWidth: content),
                       "at the window's own floor the sidebar must step aside")
    }

    // MARK: - What the window has to be

    func testRequiredWidthCountsWhatIsActuallyOnScreen() {
        XCTAssertEqual(SidebarFit.requiredWidth(sidebarPreferredOpen: true,
                                                contentMinWidth: content),
                       content + sidebar)
        XCTAssertEqual(SidebarFit.requiredWidth(sidebarPreferredOpen: false,
                                                contentMinWidth: content),
                       content)
        XCTAssertEqual(SidebarFit.requiredWidth(sidebarPreferredOpen: true,
                                                contentMinWidth: content + 340),
                       content + sidebar + 340)
    }

    /// The requirement follows the *preference*, not the drawing. A window
    /// that stopped needing the sidebar's width the moment the sidebar
    /// auto-collapsed would never grow back, and the sidebar would be gone for
    /// good.
    func testARequirementAnAutoCollapseCannotErase() {
        var fit = SidebarFit()
        fit.widthChanged(content, contentMinWidth: content)                // too narrow: sidebar hides
        XCTAssertTrue(fit.isCollapsed(preference: false))
        XCTAssertEqual(SidebarFit.requiredWidth(sidebarPreferredOpen: true,
                                                contentMinWidth: content),
                       content + sidebar,
                       "still asking for the sidebar it just had to hide")
    }

    // MARK: - Preference vs window

    func testTheWindowOverrulesAnOpenPreference() {
        var fit = SidebarFit()
        fit.widthChanged(content + sidebar - 1, contentMinWidth: content)
        XCTAssertTrue(fit.isCramped)
        XCTAssertTrue(fit.isCollapsed(preference: false),
                      "no room means no sidebar, whatever was asked for")
    }

    func testThePreferenceSurvivesTheWindowGettingNarrowAndWideAgain() {
        var fit = SidebarFit()
        fit.widthChanged(content + sidebar + 300, contentMinWidth: content)
        XCTAssertFalse(fit.isCollapsed(preference: false))

        fit.widthChanged(content, contentMinWidth: content)                    // dragged in
        XCTAssertTrue(fit.isCollapsed(preference: false))

        fit.widthChanged(content + sidebar + 300, contentMinWidth: content)    // dragged back out
        XCTAssertFalse(fit.isCollapsed(preference: false),
                       "the sidebar comes back on its own")
        XCTAssertTrue(fit.isCollapsed(preference: true),
                      "and a user who hid it still has it hidden")
    }

    /// Collapsing frees the sidebar's width, but the measurement is of the
    /// *window* — so the answer cannot feed back into itself and oscillate.
    func testTheDecisionDoesNotDependOnItsOwnOutcome() {
        var fit = SidebarFit()
        fit.widthChanged(content, contentMinWidth: content)
        let once = fit.isCramped
        fit.widthChanged(content, contentMinWidth: content)
        XCTAssertEqual(fit.isCramped, once)
    }
}


/// The toggle is really in the bar, and the traffic lights really get their
/// room back.
///
/// Both are `if`-gated on environment state, which is the shape that fails by
/// drawing nothing at all — so these are measured rather than asserted.
@MainActor
final class SidebarToggleLayoutTests: XCTestCase {
    private func barWidth(_ control: SidebarControl) -> CGFloat {
        let bar = BenchTopBar(title: "Studio") { EmptyView() }
            .environment(\.sidebarControl, control)
        let host = NSHostingView(rootView: bar)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// No sidebar to toggle — previews and offscreen hosts — draws no button.
    func testTheBarIsUnchangedWhereThereIsNoSidebar() {
        let bare = barWidth(SidebarControl())
        let withToggle = barWidth(SidebarControl(toggle: {}))
        XCTAssertGreaterThan(withToggle, bare,
                             "the button has to take room, or it is not drawn")
    }

    /// Collapsed, the bar starts clear of the traffic lights; open, the
    /// sidebar's own blank strip is holding them and the bar owes them
    /// nothing.
    func testCollapsingBuysExactlyTheTrafficLightInset() {
        let open = barWidth(SidebarControl(isCollapsed: false, toggle: {}))
        let shut = barWidth(SidebarControl(isCollapsed: true, toggle: {}))
        XCTAssertEqual(shut - open, Bench.Metrics.trafficLightInset,
                       accuracy: 0.5)
    }

    /// The inset has to actually clear the lights. Three 12 pt buttons with
    /// 8 pt gaps start 20 pt in and end at 72; the bar's own 20 pt of padding
    /// plus this inset has to reach past that.
    func testTheInsetClearsTheTrafficLights() {
        XCTAssertGreaterThanOrEqual(20 + Bench.Metrics.trafficLightInset, 72)
    }
}


/// Growing the window to fit what is in it.
///
/// `.frame(minWidth:)` only raises `NSWindow.contentMinSize`, which stops a
/// drag and moves nothing. Measured on a bare window: raising it from 200 to
/// 1000 leaves a 600 pt window at 600. So the width is applied by hand, under
/// these two rules.
final class WindowGrowthTests: XCTestCase {
    func testItGrowsToWhatIsNeeded() {
        XCTAssertEqual(WindowGrowth.target(current: 900, required: 1210,
                                           screenLimit: 1800), 1210)
    }

    /// The rule that keeps it out of the user's way: unpinning the queue drops
    /// the requirement by 340 pt, and a window that shrank on its own there
    /// would undo a deliberate drag.
    func testItNeverTakesWidthAway() {
        XCTAssertNil(WindowGrowth.target(current: 1600, required: 1210,
                                         screenLimit: 1800))
        XCTAssertNil(WindowGrowth.target(current: 1210, required: 1210,
                                         screenLimit: 1800))
    }

    /// A display cannot be outgrown. What the window cannot get is what the
    /// sidebar's own collapse is for.
    func testItStopsAtTheDisplay() {
        XCTAssertEqual(WindowGrowth.target(current: 900, required: 2400,
                                           screenLimit: 1440), 1440)
    }

    /// Once clamped, it must not keep asking — every layout pass would attempt
    /// the same resize forever.
    func testItSettlesOnceClamped() {
        XCTAssertNil(WindowGrowth.target(current: 1440, required: 2400,
                                         screenLimit: 1440))
    }

    /// Widening pushes the right edge out, so a window near the right of the
    /// display has to be walked back onto it.
    func testAWidenedWindowStaysOnItsDisplay() {
        // 1400 wide window growing to 1200 at x=900 on a 0…1440 display: its
        // right edge would land at 2100.
        XCTAssertEqual(WindowGrowth.originX(current: 900, width: 1200,
                                            screenMinX: 0, screenMaxX: 1440),
                       240)
        // Already comfortably on screen: left alone.
        XCTAssertEqual(WindowGrowth.originX(current: 100, width: 1200,
                                            screenMinX: 0, screenMaxX: 1440),
                       100)
        // Wider than the display: pinned to its left edge rather than pushed
        // off the other side.
        XCTAssertEqual(WindowGrowth.originX(current: 300, width: 1600,
                                            screenMinX: 0, screenMaxX: 1440),
                       0)
        // A second display sitting to the right of the first.
        XCTAssertEqual(WindowGrowth.originX(current: 2600, width: 800,
                                            screenMinX: 1440, screenMaxX: 3000),
                       2200)
    }
}
