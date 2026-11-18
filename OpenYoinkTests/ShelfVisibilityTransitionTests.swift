import XCTest
@testable import OpenYoink

final class ShelfVisibilityTransitionTests: XCTestCase {
    func testReopeningInvalidatesAnUnfinishedHide() throws {
        var transition = ShelfVisibilityTransitionState()
        _ = transition.request(visible: true)
        let hide = try XCTUnwrap(transition.request(visible: false))
        _ = transition.request(visible: true)

        XCTAssertFalse(transition.isCurrent(hide, visible: false))
    }

    func testOldHideCannotFinishDuringASecondHide() throws {
        var transition = ShelfVisibilityTransitionState()
        _ = transition.request(visible: true)
        let firstHide = try XCTUnwrap(transition.request(visible: false))
        _ = transition.request(visible: true)
        let secondHide = try XCTUnwrap(transition.request(visible: false))

        XCTAssertFalse(transition.isCurrent(firstHide, visible: false))
        XCTAssertTrue(transition.isCurrent(secondHide, visible: false))
    }

    func testRepeatedNotificationsDoNotRestartTheSameFade() throws {
        var transition = ShelfVisibilityTransitionState()
        let show = try XCTUnwrap(transition.request(visible: true))
        XCTAssertNil(transition.request(visible: true))
        XCTAssertTrue(transition.isCurrent(show, visible: true))

        let hide = try XCTUnwrap(transition.request(visible: false))
        XCTAssertNil(transition.request(visible: false))
        XCTAssertTrue(transition.isCurrent(hide, visible: false))
    }
}

@MainActor
final class ShelfEdgeHandoffTests: XCTestCase {
    func testClosingReleasesShelfToggleBeforeItReleasesEdge() {
        let appState = AppState()
        XCTAssertFalse(appState.isShelfVisible)
        XCTAssertTrue(appState.canShowEdgeTab)

        appState.showShelf()
        XCTAssertTrue(appState.isShelfVisible)
        XCTAssertFalse(appState.canShowEdgeTab)

        appState.beginShelfClose()
        XCTAssertFalse(appState.isShelfVisible)
        XCTAssertFalse(appState.canShowEdgeTab, "Keep the tab out while the Shelf is still animating")

        appState.hideShelf()
        XCTAssertTrue(appState.canShowEdgeTab, "The tab returns once the Shelf has been ordered out")
    }

    func testRapidReopenKeepsEdgeReservedAndInvalidatesOldClose() throws {
        let appState = AppState()
        var transition = ShelfVisibilityTransitionState()
        _ = transition.request(visible: true)
        appState.showShelf()
        let firstClose = try XCTUnwrap(transition.request(visible: false))
        appState.beginShelfClose()

        _ = transition.request(visible: true)
        appState.showShelf()
        XCTAssertFalse(appState.canShowEdgeTab)
        XCTAssertFalse(transition.isCurrent(firstClose, visible: false))

        let secondClose = try XCTUnwrap(transition.request(visible: false))
        appState.beginShelfClose()
        XCTAssertFalse(appState.canShowEdgeTab)
        XCTAssertFalse(transition.isCurrent(firstClose, visible: false))
        XCTAssertTrue(transition.isCurrent(secondClose, visible: false))
    }
}
