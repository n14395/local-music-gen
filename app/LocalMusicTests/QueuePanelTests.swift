import XCTest
@testable import LocalMusic

/// The queue panel's one rule: it opens itself on a rising edge of work and
/// never on anything else. Every case here is a sequence the app can actually
/// produce, because the bugs this guards against are all sequences — a panel
/// that reopens on every progress tick, or that never reopens for the second
/// batch.
final class QueuePanelTests: XCTestCase {
    func testStartsClosed() {
        XCTAssertFalse(QueuePanel().isOpen)
    }

    func testWorkStartingOpensIt() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isOpen)
    }

    /// The store republishes on every progress event, so `workChanged(true)`
    /// arrives dozens of times per render. Only the first may open the panel —
    /// otherwise closing it during a render is undone a second later.
    func testClosingDuringWorkStaysClosed() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.close()
        for _ in 0..<20 { panel.workChanged(isWorking: true) }
        XCTAssertFalse(panel.isOpen)
    }

    func testTheNextBatchOpensItAgain() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.close()
        panel.workChanged(isWorking: false)
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isOpen)
    }

    /// The last take landing is exactly when you are looking at the panel, so
    /// the queue emptying must not take it away.
    func testDrainingDoesNotCloseIt() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.workChanged(isWorking: false)
        XCTAssertTrue(panel.isOpen)
    }

    func testTogglingIsSymmetricAndIndependentOfWork() {
        var panel = QueuePanel()
        panel.toggle()
        XCTAssertTrue(panel.isOpen)
        panel.toggle()
        XCTAssertFalse(panel.isOpen)
        // Opening it by hand while nothing runs, then work arriving, must not
        // leave it in some third state.
        panel.toggle()
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isOpen)
    }

    // MARK: - Pinning

    /// A queue that arrives because you pressed Generate is the thing you are
    /// about to watch, so it takes a column rather than lying over the screen.
    func testWorkOpensItPinnedWithoutTouchingThePreference() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isPinned(preference: false))
        XCTAssertTrue(panel.pinnedByWork)
    }

    /// Unpinning a work-opened panel has to stick for that showing, or the
    /// button does nothing you can see.
    func testUnpinningOutranksTheWorkPin() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.pinChanged()
        XCTAssertFalse(panel.isPinned(preference: false))
        // …and a render still running must not put it back.
        for _ in 0..<10 { panel.workChanged(isWorking: true) }
        XCTAssertFalse(panel.isPinned(preference: false))
    }

    /// It is the render's pin, not the user's, so it goes when the panel does —
    /// otherwise opening it by hand later would find it mysteriously pinned.
    func testClosingForgetsTheWorkPin() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.close()
        panel.toggle()
        XCTAssertTrue(panel.isOpen)
        XCTAssertFalse(panel.isPinned(preference: false))
    }

    func testAStoredPinStillWinsOnItsOwn() {
        var panel = QueuePanel()
        panel.toggle()
        XCTAssertTrue(panel.isPinned(preference: true))
        XCTAssertFalse(panel.isPinned(preference: false))
    }

    /// The same shape as the open/close rule: a choice made during one batch
    /// does not bind the next one.
    func testTheNextBatchPinsAgain() {
        var panel = QueuePanel()
        panel.workChanged(isWorking: true)
        panel.pinChanged()
        panel.workChanged(isWorking: false)
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isPinned(preference: false))
    }

    /// A pinned panel takes its width out of the screen behind it; a floating
    /// one does not; and a *closed* panel takes nothing however it is pinned —
    /// the pin says where it goes when it opens, not that it is open.
    func testOnlyAPinnedAndOpenPanelReservesSpace() {
        XCTAssertEqual(QueuePanel.gutter(isOpen: true, isPinned: true, width: 340), 340)
        XCTAssertEqual(QueuePanel.gutter(isOpen: true, isPinned: false, width: 340), 0)
        XCTAssertEqual(QueuePanel.gutter(isOpen: false, isPinned: true, width: 340), 0)
        XCTAssertEqual(QueuePanel.gutter(isOpen: false, isPinned: false, width: 340), 0)
    }

    /// Closing it while idle is not the same act as closing it during a batch,
    /// and the difference must not be remembered: the next batch opens it.
    func testClosingWhileIdleDoesNotSuppressTheNextBatch() {
        var panel = QueuePanel()
        panel.toggle()
        panel.close()
        panel.workChanged(isWorking: true)
        XCTAssertTrue(panel.isOpen)
    }
}
