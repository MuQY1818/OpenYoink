import XCTest
@testable import OpenYoink

/// issue #10：拉环 ↔ 面板形变起点（玻璃面局部坐标，左上原点）。
final class ShelfRevealGeometryTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let inset: CGFloat = 8

    private func surface(for panel: CGRect) -> CGRect {
        panel.insetBy(dx: inset, dy: inset)
    }

    func testRightAnchoredOriginSitsOnTheTabAndBleedsPastTheScreenEdge() throws {
        let panel = ShelfLayoutEngine.edgeAttachedFrame(position: .right, width: 320, height: 500,
                                                        visibleFrame: visible)!
        let tab = ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 0.5, visibleFrame: visible)!
        let rect = try XCTUnwrap(ShelfLayoutEngine.revealOriginRect(
            surfaceFrame: surface(for: panel), tabFrame: tab, position: .right, windowInset: inset))
        let s = surface(for: panel)
        // Visible part starts where the tab starts and ends at the window (screen) edge.
        XCTAssertEqual(s.minX + rect.minX, tab.minX, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, s.width + inset + ShelfLayoutEngine.revealEdgeBleed, accuracy: 0.001)
        // Same vertical span as the tab (SwiftUI y grows downward).
        XCTAssertEqual(s.maxY - rect.minY, tab.maxY, accuracy: 0.001)
        XCTAssertEqual(rect.height, tab.height, accuracy: 0.001)
    }

    func testLeftAnchoredOriginMirrorsTheRightEdge() throws {
        let panel = ShelfLayoutEngine.edgeAttachedFrame(position: .left, width: 320, height: 500,
                                                        visibleFrame: visible)!
        let tab = ShelfLayoutEngine.edgeTabFrame(position: .left, offset: 0.5, visibleFrame: visible)!
        let rect = try XCTUnwrap(ShelfLayoutEngine.revealOriginRect(
            surfaceFrame: surface(for: panel), tabFrame: tab, position: .left, windowInset: inset))
        XCTAssertEqual(rect.minX, -inset - ShelfLayoutEngine.revealEdgeBleed, accuracy: 0.001)
        XCTAssertEqual(surface(for: panel).minX + rect.maxX, tab.maxX, accuracy: 0.001)
    }

    func testTabOutsideThePanelSpanGrowsFromTheNearestPoint() throws {
        // A short panel at the bottom while the tab sits near the top.
        let panel = CGRect(x: 1120, y: 0, width: 320, height: 240)
        let tab = ShelfLayoutEngine.edgeTabFrame(position: .right, offset: 1, visibleFrame: visible)!
        let s = surface(for: panel)
        let rect = try XCTUnwrap(ShelfLayoutEngine.revealOriginRect(
            surfaceFrame: s, tabFrame: tab, position: .right, windowInset: inset))
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect.maxY, s.height)
    }

    func testCustomPositionHasNoMorphOrigin() {
        XCTAssertNil(ShelfLayoutEngine.revealOriginRect(
            surfaceFrame: CGRect(x: 100, y: 100, width: 300, height: 400),
            tabFrame: CGRect(x: 0, y: 0, width: 14, height: 84),
            position: .custom, windowInset: inset))
    }
}
