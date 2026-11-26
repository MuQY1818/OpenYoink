import CoreGraphics
import XCTest
@testable import OpenYoink

final class EdgeTabLayoutTests: XCTestCase {
    func testIconAlwaysLeavesPaddingInsideNormalAndEmphasizedTabs() {
        for size in stride(from: 6.0, through: 10.0, by: 1) {
            for width in [ShelfLayoutEngine.edgeTabWidth, ShelfLayoutEngine.edgeTabEmphasizedWidth] {
                let bounds = CGRect(x: 0, y: 0, width: width, height: 84)
                let icon = ShelfLayoutEngine.edgeTabIconFrame(in: bounds, size: size)
                XCTAssertTrue(bounds.insetBy(dx: 2, dy: 2).contains(icon))
                XCTAssertEqual(icon.width, CGFloat(size))
                XCTAssertEqual(icon.midX, bounds.midX)
                XCTAssertEqual(icon.midY, bounds.midY)
            }
        }
    }

    func testIconRemainsContainedWhenAvailableBoundsShrink() {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 7)
        let icon = ShelfLayoutEngine.edgeTabIconFrame(in: bounds, size: 10)
        XCTAssertEqual(icon.size, CGSize(width: 3, height: 3))
        XCTAssertTrue(bounds.insetBy(dx: 2, dy: 2).contains(icon))
    }

    private let mainScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 1020)
    )

    func testEdgeTabFrame_rightEdgeOffsetHalfIsVerticallyCentered() {
        // Travel = 1020−84 = 936; center y = 60 + 42 + 936×0.5 = 570 → y = 528.
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 528, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_leftEdgeAnchorsToVisibleMinX() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .left, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 528, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_offsetExtremesPinToBottomAndTop() {
        // offset 0: the tab's bottom on the visible bottom; offset 1: top on top.
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 60, width: 14, height: 84)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1,
                                           visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1906, y: 996, width: 14, height: 84)
        )
    }

    func testEdgeTabFrame_outOfRangeOffsetClamps() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: -0.5,
                                           visibleFrame: mainScreen.visibleFrame),
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0,
                                           visibleFrame: mainScreen.visibleFrame)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1.5,
                                           visibleFrame: mainScreen.visibleFrame),
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1,
                                           visibleFrame: mainScreen.visibleFrame)
        )
    }

    func testEdgeTabFrame_customReturnsNil() {
        XCTAssertNil(
            ShelfLayoutEngine.edgeTabFrame(position: .custom, offset: 0.5,
                                           visibleFrame: mainScreen.visibleFrame)
        )
    }

    func testEdgeTabFrame_tinyVisibleHeightShrinksTab() {
        // Visible height below the tab's: shrink to fit, no travel, never out of bounds.
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 60)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0.7, visibleFrame: tiny),
            CGRect(x: 786, y: 0, width: 14, height: 60)
        )
    }

    func testEdgeTabOffset_mapsBottomCenterAndTop() {
        // Bottom on bottom (center 60+42=102) → 0; centered (60+510=570) → 0.5;
        // top on top (center 60+1020−42=1038) → 1.
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 102,
                                                       visibleFrame: mainScreen.visibleFrame), 0)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 570,
                                                       visibleFrame: mainScreen.visibleFrame), 0.5)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 1038,
                                                       visibleFrame: mainScreen.visibleFrame), 1)
    }

    func testEdgeTabOffset_clampsBeyondVisibleArea() {
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: -100,
                                                       visibleFrame: mainScreen.visibleFrame), 0)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 5000,
                                                       visibleFrame: mainScreen.visibleFrame), 1)
    }

    func testEdgeTabOffset_noVerticalTravelFallsBackToHalf() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 60)
        XCTAssertEqual(ShelfLayoutEngine.edgeTabOffset(forCenterY: 30, visibleFrame: tiny), 0.5)
    }

    func testEdgeTabOffset_isExactInverseOfEdgeTabFrame() {
        // Persisting the offset from center y must rebuild the identical frame (no jump).
        for offset in [0, 0.25, 0.5, 0.75, 1] as [CGFloat] {
            let frame = ShelfLayoutEngine.edgeTabFrame(position: .right, offset: offset,
                                                       visibleFrame: mainScreen.visibleFrame)
            let roundTripped = ShelfLayoutEngine.edgeTabOffset(forCenterY: frame?.midY ?? 0,
                                                               visibleFrame: mainScreen.visibleFrame)
            XCTAssertEqual(roundTripped, offset, accuracy: 1e-9,
                           "offset \(offset) round-trip mismatch")
        }
    }

    func testShouldFlipSide_rightTabFlipsNearLeftEdgePastMidline() {
        // Screen width 1920, midline 960: x=100 is past it and 100 < 120 from the
// left edge → flip.
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 100, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_rightTabStaysWhenFarFromOppositeEdge() {
        // Past the midline but 150 > 120 from the left edge → no flip.
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 150, y: 500),
                                             screenFrame: mainScreen.frame)
        )
        // Still on the right half → no flip.
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 1500, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_requiresCrossingMidlineOnNarrowScreens() {
        // Narrow screen (200 wide): the 120 pt band crosses the midline (100).
        // x=110 is 110 < 120 from the left but not past the midline → no flip.
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 600)
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 110, y: 300),
                                             screenFrame: narrow)
        )
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right,
                                             cursorLocation: CGPoint(x: 90, y: 300),
                                             screenFrame: narrow)
        )
    }

    func testShouldFlipSide_leftTabFlipsNearRightEdgePastMidline() {
        // x=1820: past the midline (> 960) and 100 < 120 from the right edge → flip.
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .left,
                                             cursorLocation: CGPoint(x: 1820, y: 500),
                                             screenFrame: mainScreen.frame)
        )
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .left,
                                             cursorLocation: CGPoint(x: 1770, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_customNeverFlips() {
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .custom,
                                             cursorLocation: CGPoint(x: 100, y: 500),
                                             screenFrame: mainScreen.frame)
        )
    }

    func testShouldFlipSide_flipDistanceIsAdjustable() {
        // 130 from the opposite edge: no flip at the default 120; flips at 150.
        let cursor = CGPoint(x: 130, y: 500)
        XCTAssertFalse(
            ShelfLayoutEngine.shouldFlipSide(position: .right, cursorLocation: cursor,
                                             screenFrame: mainScreen.frame)
        )
        XCTAssertTrue(
            ShelfLayoutEngine.shouldFlipSide(position: .right, cursorLocation: cursor,
                                             screenFrame: mainScreen.frame, flipDistance: 150)
        )
    }

    func testEdgeTabEmphasisFrame_growsInwardKeepingCenterY() {
        let base = CGRect(x: 1906, y: 528, width: 14, height: 84)
        // Right edge: stays on 1920 (width 18 → x=1902); center y 570 kept (height 92 → y=524).
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .right,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1902, y: 524, width: 18, height: 92)
        )
        // Left edge: x=0 kept, grows to the right.
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: CGRect(x: 0, y: 528, width: 14, height: 84),
                                                   position: .left,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 524, width: 18, height: 92)
        )
    }

    func testEdgeTabEmphasisFrame_clampsIntoVisibleFrameAtExtremes() {
        // Tab at the bottom (midY=102): grown, y=56 would be below the edge → clamped to 60.
        let base = CGRect(x: 1906, y: 60, width: 14, height: 84)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .right,
                                                   visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 1902, y: 60, width: 18, height: 92)
        )
    }

    func testEdgeTabEmphasisFrame_customReturnsBaseUnchanged() {
        let base = CGRect(x: 100, y: 200, width: 14, height: 84)
        XCTAssertEqual(
            ShelfLayoutEngine.edgeTabEmphasisFrame(from: base, position: .custom,
                                                   visibleFrame: mainScreen.visibleFrame),
            base
        )
    }

    func testEdgeAttachedFrame_edgeOffsetPositionsAlongEdge() {
        // offset 0 → bottom on bottom; offset 1 → top on top; travel = 1020−144 = 876.
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 0),
            CGRect(x: 1600, y: 60, width: 320, height: 144)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 1),
            CGRect(x: 1600, y: 936, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_defaultOffsetKeepsLegacyCentering() {
        // No edgeOffset = 0.5: the old fixed centering (y = 60+876/2 = 498).
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 498, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_outOfRangeOffsetClamps() {
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 2),
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame,
                                                edgeOffset: 1)
        )
    }

    func testTargetFrame_edgeOffsetFlowsThrough() {
        // One item → compact height 192 (title plus status line); offset 0 → bottom right.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil,
                                          edgeOffset: 0),
            CGRect(x: 1600, y: 60, width: 320, height: 192)
        )
        // offset 1 → top: y = 60 + 860 = 920.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil,
                                          edgeOffset: 1),
            CGRect(x: 0, y: 888, width: 320, height: 192)
        )
    }

    func testTargetFrame_defaultOffsetKeepsLegacyCentering() {
        // No edgeOffset: centered with the status line, y = 474.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 300, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 0, y: 474, width: 300, height: 192)
        )
    }
}
