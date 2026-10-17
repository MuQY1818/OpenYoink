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
