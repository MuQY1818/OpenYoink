import CoreGraphics
import XCTest
@testable import OpenYoink

/// Pure edge trigger logic: the band (isInsideEdgeBand) and the dwell (EdgeDwellTracker).
final class EdgeTriggerMonitorTests: XCTestCase {
    // MARK: - Current-gesture file drag gate

    func testFileDrag_staleFilePasteboardAtMouseDownDoesNotCount() {
        var tracker = EdgeFileDragTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertFalse(tracker.mouseDragged(changeCount: 21, hasFileContent: true))
        XCTAssertFalse(tracker.hasFreshFileContent)
    }

    func testFileDrag_freshFilePasteboardAfterMouseDownCounts() {
        var tracker = EdgeFileDragTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasFileContent: true))
        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasFileContent: true))
    }

    func testFileDrag_freshBrowserPayloadDoesNotCount() {
        var tracker = EdgeFileDragTracker()
        tracker.mouseDown(changeCount: 21)

        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasFileContent: false))
        XCTAssertFalse(tracker.hasFreshFileContent)
    }

    func testFileDrag_newGestureCannotReusePreviousFileDrag() {
        var tracker = EdgeFileDragTracker()
        tracker.mouseDown(changeCount: 21)
        XCTAssertTrue(tracker.mouseDragged(changeCount: 22, hasFileContent: true))
        tracker.mouseUp()

        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasFileContent: true))
        tracker.mouseDown(changeCount: 22)
        XCTAssertFalse(tracker.mouseDragged(changeCount: 22, hasFileContent: true))
    }

    // MARK: - Edge band

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testBand_rightSide_insideAtAndBeyondBoundary() {
        // The right band is [maxX−4, maxX], bounds included.
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 996, y: 400),
                                                          screenFrame: frame, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 995.9, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
        // The left side isn't in the right band.
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_leftSide_insideAtAndBeyondBoundary() {
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4, y: 400),
                                                          screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 4.1, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999, y: 400),
                                                           screenFrame: frame, side: .left, bandWidth: 4))
    }

    func testBand_pointOutsideScreen_neverCounts() {
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1200, y: 400),
                                                           screenFrame: frame, side: .right, bandWidth: 4))
    }

    func testBand_customPosition_neverInside() {
        // Custom placement has no attached edge; no point matches.
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 999.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 0.5, y: 400),
                                                           screenFrame: frame, side: .custom, bandWidth: 4))
    }

    func testBand_nonZeroOriginScreen() {
        // A secondary screen (non-zero origin): the band follows the screen frame.
        let secondScreen = CGRect(x: 1000, y: 0, width: 1440, height: 900)
        XCTAssertTrue(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 2438, y: 100),
                                                          screenFrame: secondScreen, side: .right, bandWidth: 4))
        XCTAssertFalse(EdgeTriggerMonitor.isInsideEdgeBand(CGPoint(x: 1001, y: 100),
                                                           screenFrame: secondScreen, side: .right, bandWidth: 4))
    }

    // MARK: - Dwell tracker

    func testDwell_firesOnlyAfterThreshold() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0)) // enter, start timing
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.2))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.49))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.5))
    }

    func testDwell_exactBoundaryCounts() {
        // A dwell exactly at the threshold (>=) triggers.
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_leavingBandRearmsTimer() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.3))
        XCTAssertFalse(tracker.addSample(isInside: false, at: 0.4)) // leave: timer resets
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.5)) // enter again
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.9)) // 0.4s < 0.5s
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.0))
    }

    func testDwell_firesOncePerEntry_untilCursorLeaves() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        // Staying in the band doesn't trigger again (or a hidden shelf would come
// right back with the pointer unmoved).
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.7))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.0))
        // Only leaving and re-entering triggers again.
        XCTAssertFalse(tracker.addSample(isInside: false, at: 5.1))
        XCTAssertFalse(tracker.addSample(isInside: true, at: 5.2))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 5.8))
    }

    func testDwell_resetRearms() {
        var tracker = EdgeDwellTracker(dwellTime: 0.5)
        XCTAssertFalse(tracker.addSample(isInside: true, at: 0.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 0.6))
        tracker.reset()
        XCTAssertFalse(tracker.addSample(isInside: true, at: 1.0))
        XCTAssertTrue(tracker.addSample(isInside: true, at: 1.5))
    }

    func testDwell_neverInside_neverFires() {
        var tracker = EdgeDwellTracker(dwellTime: 0.3)
        for index in 0..<20 {
            XCTAssertFalse(tracker.addSample(isInside: false, at: TimeInterval(index) * 0.1))
        }
    }
}
