import XCTest
@testable import OpenYoink

/// Mapping a drop point to a grid insertion index (DropInsertionLocator, pure).
///
/// Grid: 3 adaptive columns, 100×64 cards, 12 spacing:
/// row 0: indices 0/1/2, x = 0/112/224, y 0...64
/// row 1: indices 3/4,   x = 0/112,     y 76...140
final class DropInsertionLocatorTests: XCTestCase {
    @MainActor
    func testOutgoingGridCannotRemoveReplacementCellsGeometry() {
        let geometry = ShelfGridGeometry()
        let itemID = UUID()
        let oldOwner = UUID()
        let newOwner = UUID()
        geometry.report(CGRect(x: 0, y: 50, width: 84, height: 100), for: itemID, owner: oldOwner)
        let replacement = CGRect(x: 0, y: 60, width: 84, height: 100)
        geometry.report(replacement, for: itemID, owner: newOwner)
        geometry.removeFrame(for: itemID, owner: oldOwner)
        XCTAssertEqual(geometry.cardFrames[itemID], replacement)
        geometry.removeFrame(for: itemID, owner: newOwner)
        XCTAssertNil(geometry.cardFrames[itemID])
    }

    private func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 100, height: 64)
    }

    private var frames: [(index: Int, frame: CGRect)] {
        [(0, frame(0, 0)), (1, frame(112, 0)), (2, frame(224, 0)),
         (3, frame(0, 76)), (4, frame(112, 76))]
    }

    private func locate(_ x: CGFloat,
                        _ y: CGFloat,
                        itemCount: Int = 5,
                        activation: DropInsertionLocator.Activation = .center) -> Int {
        DropInsertionLocator.insertionIndex(for: CGPoint(x: x, y: y),
                                            frames: frames,
                                            itemCount: itemCount,
                                            activation: activation)
    }

    func testEmptyShelfInsertsAtZero() {
        XCTAssertEqual(DropInsertionLocator.insertionIndex(for: CGPoint(x: 50, y: 50),
                                                           frames: [], itemCount: 0), 0)
    }

    /// No geometry yet (before the first layout) appends.
    func testMissingFramesFallsBackToAppend() {
        XCTAssertEqual(DropInsertionLocator.insertionIndex(for: CGPoint(x: 10, y: 10),
                                                           frames: [], itemCount: 5), 5)
    }

    func testPointLeftOfFirstCardInsertsAtZero() {
        // (30, 32): card 0's midpoint x=50 is to the right → before card 0.
        XCTAssertEqual(locate(30, 32), 0)
    }

    func testPointBetweenCardsInsertsAtNextCard() {
        // (105, 32): past card 0's midpoint (50), not card 1's (162) → index 1.
        XCTAssertEqual(locate(105, 32), 1)
    }

    func testCenterActivationPreservesMidpointSemantics() {
        XCTAssertEqual(locate(49, 32, itemCount: 3), 0)
        XCTAssertEqual(locate(51, 32, itemCount: 3), 1)
        XCTAssertEqual(locate(161, 32, itemCount: 3), 1)
        XCTAssertEqual(locate(163, 32, itemCount: 3), 2)
    }

    func testTenPercentActivationIsSymmetricAtEachLeadingEdge() {
        XCTAssertEqual(locate(9, 32, itemCount: 3, activation: .leading), 0)
        XCTAssertEqual(locate(11, 32, itemCount: 3, activation: .leading), 1)
        XCTAssertEqual(locate(121, 32, itemCount: 3, activation: .leading), 1)
        XCTAssertEqual(locate(123, 32, itemCount: 3, activation: .leading), 2)
    }

    func testTrailingActivationMirrorsLeadingAcrossEachCard() {
        XCTAssertEqual(locate(89, 32, itemCount: 3, activation: .trailing), 0)
        XCTAssertEqual(locate(91, 32, itemCount: 3, activation: .trailing), 1)
        XCTAssertEqual(locate(201, 32, itemCount: 3, activation: .trailing), 1)
        XCTAssertEqual(locate(203, 32, itemCount: 3, activation: .trailing), 2)
    }

    /// Dragging straight up a column must take that column's slot. The old
    /// trailing-edge rule for rows above the card left the slot one place
    /// behind, which is what made vertical and diagonal drags feel stuck.
    func testVerticalEntryFollowsTheColumnInsteadOfTheHorizontalEdge() {
        XCTAssertEqual(locate(161, 100, itemCount: 5, activation: .center), 4)
        XCTAssertEqual(locate(162, 32, itemCount: 5, activation: .center), 2)
        XCTAssertEqual(locate(162, 32, itemCount: 5, activation: .trailing), 1)
        XCTAssertEqual(locate(50, 32, itemCount: 5, activation: .center), 1)
        XCTAssertEqual(locate(50, 100, itemCount: 5, activation: .center), 4)
    }

    /// A diagonal move that is mostly horizontal keeps the eager entry-edge
    /// behavior after changing rows.
    func testDiagonalEntryKeepsDirectionalActivation() {
        XCTAssertEqual(locate(123, 32, itemCount: 5, activation: .leading), 2)
        XCTAssertEqual(locate(201, 32, itemCount: 5, activation: .trailing), 1)
    }

    func testPointRightOfRowEndInsertsAfterRow() {
        // (300, 32): right of row 0's last card (index 2) → 3 (the next row's first slot).
        XCTAssertEqual(locate(300, 32), 3)
    }

    func testSecondRowMapsToSecondRowIndices() {
        XCTAssertEqual(locate(30, 100), 3)
        XCTAssertEqual(locate(105, 100), 4)
    }

    func testVariableHeightCardsWithSharedCenterStayInOneRow() {
        let variableFrames = [
            (0, CGRect(x: 0, y: 0, width: 100, height: 125)),
            (1, CGRect(x: 112, y: 15.5, width: 100, height: 94)),
            (2, CGRect(x: 224, y: 15.5, width: 100, height: 94)),
        ]

        let middle = DropInsertionLocator.insertionIndex(
            for: CGPoint(x: 170, y: 100),
            frames: variableFrames,
            itemCount: 3,
            activation: .leading
        )
        let trailing = DropInsertionLocator.insertionIndex(
            for: CGPoint(x: 245, y: 100),
            frames: variableFrames,
            itemCount: 3,
            activation: .leading
        )

        XCTAssertEqual(middle, 2)
        XCTAssertEqual(trailing, 3)
    }

    /// Right of the last row's last card → itemCount (append).
    func testLastRowEndAppends() {
        XCTAssertEqual(locate(300, 100), 5)
    }

    /// Blank space below the grid matches no row → append.
    func testBelowGridAppends() {
        XCTAssertEqual(locate(160, 300), 5)
    }

    /// Above the first row (the title bar) also appends, never inserts first.
    func testAboveFirstRowAppends() {
        XCTAssertEqual(locate(160, -100), 5)
    }

    /// The gap between rows belongs to the row above (rowGapSlack 6 pt).
    func testRowGapBelongsToUpperRow() {
        XCTAssertEqual(locate(30, 70), 0)   // row 0's territory ends at 64+6=70, inclusive
        XCTAssertEqual(locate(30, 71), 3)   // row 1's territory (from 76−6=70)
    }

    /// With some card geometry missing, approximate from what exists without crashing.
    func testPartialFramesDegradeGracefully() {
        let partial = [(index: 3, frame: frame(0, 76)), (index: 4, frame: frame(112, 76))]
        XCTAssertEqual(DropInsertionLocator.insertionIndex(for: CGPoint(x: 30, y: 100),
                                                           frames: partial, itemCount: 5), 3)
        XCTAssertEqual(DropInsertionLocator.insertionIndex(for: CGPoint(x: 160, y: 300),
                                                           frames: partial, itemCount: 5), 5)
    }
}
