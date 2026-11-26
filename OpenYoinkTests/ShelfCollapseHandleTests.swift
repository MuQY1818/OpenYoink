import XCTest
@testable import OpenYoink

/// Which side the collapse handle is on (`ShelfLayoutEngine.innerEdgeHandleSide`):
/// always the inner edge facing the screen center; none for custom placement.
final class ShelfCollapseHandleTests: XCTestCase {
    func testHandleSide_rightAnchoredShelf_placesHandleOnLeadingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .right), .leading)
    }

    func testHandleSide_leftAnchoredShelf_placesHandleOnTrailingEdge() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleSide(for: .left), .trailing)
    }

    func testHandleSide_customPosition_hasNoHandle() {
        XCTAssertNil(ShelfLayoutEngine.innerEdgeHandleSide(for: .custom))
    }

    func testHandleWidth_fitsInsidePanelMarginBand() {
        XCTAssertEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 10)
        XCTAssertLessThanOrEqual(ShelfLayoutEngine.innerEdgeHandleWidth, 16)
    }
}
