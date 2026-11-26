import CoreGraphics
import XCTest
@testable import OpenYoink

/// 25 → visibleFrame (1920,25 2560×1415)
final class ShelfLayoutEngineTests: XCTestCase {
    func testGridOnlyOmitsScrollingWhenItsRowsFit() {
        let oneRow = CGSize(width: 276, height: 132)
        XCTAssertTrue(ShelfLayoutEngine.gridFits(itemCount: 3, viewport: oneRow))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 4, viewport: oneRow))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: CGSize(width: 284, height: 131)))
        XCTAssertTrue(ShelfLayoutEngine.gridFits(itemCount: 4, viewport: CGSize(width: 284, height: 276)))
        // Narrow shelves and incomplete initial layout must keep the scroll path.
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: .zero))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 1, viewport: CGSize(width: 83, height: 300)))
        XCTAssertFalse(ShelfLayoutEngine.gridFits(itemCount: 3, viewport: CGSize(width: 275, height: 132)))
    }

    private let mainScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 60, width: 1920, height: 1020)
    )
    private let secondaryScreen = ShelfLayoutEngine.ScreenGeometry(
        frame: CGRect(x: 1920, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1920, y: 25, width: 2560, height: 1415)
    )

    func testEdgeAttachedFrame_leftAnchorsToVisibleMinX_andCentersVertically() {
        // y = 60 + (1020-144)/2 = 498
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame),
            CGRect(x: 0, y: 498, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_rightAnchorsToVisibleMaxX_andCentersVertically() {
        // x = 4480-320 = 4160y = 25 + (1415-144)/2 = 660.5
        XCTAssertEqual(
            ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 144,
                                                visibleFrame: secondaryScreen.visibleFrame),
            CGRect(x: 4160, y: 660.5, width: 320, height: 144)
        )
    }

    func testEdgeAttachedFrame_customHasNoEdge() {
        XCTAssertNil(
            ShelfLayoutEngine.edgeAttachedFrame(position: .custom, width: 320, height: 144,
                                                visibleFrame: mainScreen.visibleFrame)
        )
    }

    // MARK: - Hidden frame

    func testHiddenFrame_offsetsAwayFromAttachmentEdge() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .right),
                       CGRect(x: 1920, y: 60, width: 320, height: 1020))
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .left),
                       CGRect(x: 1280, y: 60, width: 320, height: 1020))
    }

    func testHiddenFrame_customStaysInPlace() {
        // Custom doesn't slide: hiding only fades.
        let frame = CGRect(x: 500, y: 300, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.hiddenFrame(for: frame, position: .custom), frame)
    }

    // MARK: - Clamping

    func testClamped_frameInsideReturnsSelf() {
        let frame = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame), frame)
    }

    func testClamped_movesOriginMinimallyIntoBounds() {
        // Past the right and top edges: x becomes maxX−width, y maxY−height.
        let frame = CGRect(x: 1700, y: 1000, width: 320, height: 300)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 1600, y: 780, width: 320, height: 300))
    }

    func testClamped_shrinksOversizedFrame() {
        let frame = CGRect(x: -100, y: -100, width: 3000, height: 2000)
        XCTAssertEqual(ShelfLayoutEngine.clamped(frame, into: mainScreen.visibleFrame),
                       CGRect(x: 0, y: 60, width: 1920, height: 1020))
    }

    // MARK: - Target screen

    func testTargetScreen_prefersScreenContainingMouse() {
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 500, y: 500),
                                                      screens: screens), mainScreen)
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: 2000, y: 100),
                                                      screens: screens), secondaryScreen)
    }

    func testTargetScreen_mouseOffAllScreensFallsBackToMain() {
        // The pointer's screen was just unplugged → the first (main) screen.
        let screens = [mainScreen, secondaryScreen]
        XCTAssertEqual(ShelfLayoutEngine.targetScreen(mouseLocation: CGPoint(x: -50, y: 3000),
                                                      screens: screens), mainScreen)
    }

    func testTargetScreen_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.targetScreen(mouseLocation: .zero, screens: []))
    }

    // MARK: - Custom frame validation

    func testValidatedCustomFrame_insideScreenKeepsPosition() {
        let persisted = CGRect(x: 100, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            persisted
        )
    }

    func testValidatedCustomFrame_appliesCurrentWidthSetting() {
        // Width from settings: persisted 300, setting 400 → 400, origin unchanged.
        let persisted = CGRect(x: 100, y: 200, width: 300, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 400, screens: [mainScreen]),
            CGRect(x: 100, y: 200, width: 400, height: 600)
        )
    }

    func testValidatedCustomFrame_partiallyOutsideClampsIntoVisibleFrame() {
        // After a resolution drop the persisted frame is past the right and top → clamped.
        let persisted = CGRect(x: 1800, y: 500, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320, screens: [mainScreen]),
            CGRect(x: 1600, y: 480, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_straddlingScreensPicksLargestIntersection() {
        // Spanning both screens: more area on the secondary → clamped into it.
        let persisted = CGRect(x: 1800, y: 200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen]),
            CGRect(x: 1920, y: 200, width: 320, height: 600)
        )
    }

    func testValidatedCustomFrame_offAllScreensReturnsNil() {
        // The persisted frame's screen is gone → nil; the caller falls back.
        let persisted = CGRect(x: 5000, y: 5000, width: 320, height: 600)
        XCTAssertNil(
            ShelfLayoutEngine.validatedCustomFrame(persisted, width: 320,
                                                   screens: [mainScreen, secondaryScreen])
        )
    }

    // MARK: - Full target-frame decision

    func testTargetFrame_edgePositionsFollowMouseScreen() {
        let screens = [mainScreen, secondaryScreen]
        // Pointer on the secondary → its right edge; one item, one row with the
// status line = 192, centered.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 1,
                                          mouseLocation: CGPoint(x: 2000, y: 100),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 4160, y: 636.5, width: 320, height: 192)
        )
        // Pointer on the main screen → its left edge.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .left, width: 300, itemCount: 1,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: screens, persistedCustomFrame: nil),
            CGRect(x: 0, y: 474, width: 300, height: 192)
        )
    }

    func testTargetFrame_emptyShelfUsesCompactEmptyHeight() {
        // Empty: compact height 200, centered → y = 60 + (1020−200)/2 = 470.
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 0,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 470, width: 320, height: 200)
        )
    }

    func testTargetFrame_customWithoutPersistedStartsAtRightEdge() {
        // First custom (nothing persisted) → the right-edge default on the pointer's
        // screen (custom keeps the full-height default).
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 5,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen], persistedCustomFrame: nil),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_customWithValidPersistedStaysWhereUserPlacedIt() {
        // Custom doesn't follow the pointer: persisted on the secondary, pointer on
// the main screen, still where it was.
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 3,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen, secondaryScreen],
                                          persistedCustomFrame: persisted),
            persisted
        )
    }

    func testTargetFrame_customWithUnpluggedPersistedScreenFallsBackToRightEdge() {
        // The persisted frame's screen is gone → right-edge default on the pointer's
// screen (or the main one).
        let persisted = CGRect(x: 2000, y: 100, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 2,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen],
                                          persistedCustomFrame: persisted),
            CGRect(x: 1600, y: 60, width: 320, height: 1020)
        )
    }

    func testTargetFrame_emptyScreensReturnsFallback() {
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right, width: 320, itemCount: 4,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: nil),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .custom, width: 320, itemCount: 0,
                                          mouseLocation: .zero, screens: [],
                                          persistedCustomFrame: CGRect(x: 100, y: 100, width: 320, height: 600)),
            CGRect(origin: .zero, size: ShelfLayoutEngine.fallbackSize)
        )
    }

    func testColumnCount_matchesAdaptiveGridMath() {
        // 88 pt minimum column + 12 spacing; panel padding totals 32.
        // 320 → grid 288 → 3 columns (3×88+2×12=288 fits exactly).
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 320), 3)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 240), 2)
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 420), 4)
        // Narrower than one column still gets one.
        XCTAssertEqual(ShelfLayoutEngine.columnCount(forPanelWidth: 100), 1)
    }

    func testContentHeight_singleRowForUpToFullRowOfItems() {
        // 3 columns: 1–3 items are one row → 28 + 132 + 32 = 192.
        for count in 1...3 {
            XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: count, panelWidth: 320,
                                                           visibleHeight: 1020), 192)
        }
    }

    func testContentHeight_growsByRow() {
        // 4 items, 2 rows → 28 + (132×2 + 12) + 32 = 336; 7 items, 3 rows → 480.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 4, panelWidth: 320,
                                                       visibleHeight: 1020), 336)
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 7, panelWidth: 320,
                                                       visibleHeight: 1020), 480)
    }

    func testContentHeight_narrowerPanelFitsFewerColumnsHenceMoreRows() {
        // Width 240 → 2 columns: 3 items are 2 rows → 336.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 240,
                                                       visibleHeight: 1020), 336)
    }

    func testContentHeight_capsAtEightyPercentOfVisibleHeight() {
        // Visible height 300 → cap 240; 10 items in 4 rows exceed it → 240 (the rest scrolls).
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 10, panelWidth: 320,
                                                       visibleHeight: 300), 240)
    }

    func testContentHeight_emptyShelfUsesCompactPlaceholderCappedOnTinyScreens() {
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 1020), 200)
        // A tiny screen: the empty state obeys the 80 % cap too.
        XCTAssertEqual(ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                                       visibleHeight: 200), 160)
    }

    func testContentHeight_activityStripReservesSpaceWithoutExceedingCap() {
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000, hasActivity: true),
            ShelfLayoutEngine.contentHeight(itemCount: 3, panelWidth: 320,
                                            visibleHeight: 1000)
                + ShelfLayoutEngine.activityStripHeight
        )
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 20, panelWidth: 240,
                                            visibleHeight: 300, hasActivity: true),
            240
        )
    }

    func testContentHeight_quickActionsReserveOneCompactRow() {
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 1, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasQuickActions: true),
            236
        )
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 1, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasActivity: true,
                                            hasQuickActions: true),
            322
        )
        // An empty shelf cannot have an explicit selection; the defensive
        // input must not create a floating action-only row.
        XCTAssertEqual(
            ShelfLayoutEngine.contentHeight(itemCount: 0, panelWidth: 320,
                                            visibleHeight: 1020,
                                            hasQuickActions: true),
            200
        )
    }

    func testTargetFrame_quickActionsRemainEdgeAttachedAndCentered() {
        XCTAssertEqual(
            ShelfLayoutEngine.targetFrame(position: .right,
                                          width: 320,
                                          itemCount: 1,
                                          hasQuickActions: true,
                                          mouseLocation: CGPoint(x: 500, y: 500),
                                          screens: [mainScreen],
                                          persistedCustomFrame: nil),
            CGRect(x: 1600, y: 452, width: 320, height: 236)
        )
    }

    // MARK: - Space-change correction

    func testOnscreenCorrection_validFrameUnchanged() {
        let frame = CGRect(x: 1600, y: 60, width: 320, height: 1020)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            frame
        )
    }

    func testOnscreenCorrection_partiallyOffscreenClampsBack() {
        let frame = CGRect(x: 100, y: -200, width: 320, height: 600)
        XCTAssertEqual(
            ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]),
            CGRect(x: 100, y: 60, width: 320, height: 600)
        )
    }

    func testOnscreenCorrection_fullyOffscreenReturnsNil() {
        let frame = CGRect(x: 9000, y: 9000, width: 320, height: 600)
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: frame, screens: [mainScreen]))
    }

    func testOnscreenCorrection_emptyScreensReturnsNil() {
        XCTAssertNil(ShelfLayoutEngine.onscreenCorrection(for: .zero, screens: []))
    }
}
