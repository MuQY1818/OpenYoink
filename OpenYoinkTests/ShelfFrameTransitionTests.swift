import XCTest
@testable import OpenYoink

final class ShelfFrameTransitionTests: XCTestCase {
    func testRepeatedLayoutRequestDoesNotInterruptEitherEdgeSlide() {
        for position in [SettingsStore.ShelfPosition.left, .right] {
            let target = CGRect(x: position == .left ? 0 : 1120,
                                y: 200, width: 320, height: 500)
            let hidden = ShelfLayoutEngine.hiddenFrame(for: target, position: position)
            var transition = ShelfFrameTransitionState()
            XCTAssertTrue(transition.request(target, currentFrame: hidden))

            let halfway = CGRect(x: (hidden.minX + target.minX) / 2,
                                  y: target.minY, width: target.width, height: target.height)
            XCTAssertFalse(transition.request(target, currentFrame: halfway),
                           "An unrelated notification must not replace the in-flight slide")
            XCTAssertFalse(transition.request(target, currentFrame: hidden),
                           "Duplicate observers must leave the same slide alone")
            XCTAssertEqual(transition.targetFrame, target)
        }
    }

    func testWidthAndHeightChangesRetargetOnceDuringOpening() {
        var transition = ShelfFrameTransitionState()
        let opening = CGRect(x: 1120, y: 200, width: 320, height: 500)
        let halfway = opening.offsetBy(dx: 160, dy: 0)
        _ = transition.request(opening, currentFrame: halfway)
        let resized = CGRect(x: 1040, y: 150, width: 400, height: 600)

        XCTAssertTrue(transition.request(resized, currentFrame: halfway))
        XCTAssertFalse(transition.request(resized, currentFrame: halfway))
        XCTAssertEqual(transition.targetFrame, resized)
    }

    func testHideThenReopenToSameFrameStartsANewTransition() {
        var transition = ShelfFrameTransitionState()
        let target = CGRect(x: 1120, y: 200, width: 320, height: 500)
        _ = transition.request(target, currentFrame: target)
        transition.reset()
        XCTAssertNil(transition.targetFrame)

        let hidden = ShelfLayoutEngine.hiddenFrame(for: target, position: .right)
        XCTAssertTrue(transition.request(target, currentFrame: hidden))
        XCTAssertFalse(transition.request(target, currentFrame: hidden))
    }

    func testScreenCorrectionReplacesPreviousDestination() {
        var transition = ShelfFrameTransitionState()
        let oldScreen = CGRect(x: 2560, y: 200, width: 320, height: 500)
        _ = transition.request(oldScreen, currentFrame: oldScreen)
        let newScreen = CGRect(x: 1120, y: 200, width: 320, height: 500)

        XCTAssertTrue(transition.request(newScreen, currentFrame: oldScreen))
        XCTAssertFalse(transition.request(newScreen, currentFrame: newScreen))
        XCTAssertEqual(transition.targetFrame, newScreen)
    }

    func testAlreadyPositionedPanelEstablishesDestinationWithoutMoving() {
        var transition = ShelfFrameTransitionState()
        let custom = CGRect(x: 300, y: 200, width: 320, height: 500)
        XCTAssertFalse(transition.request(custom, currentFrame: custom))
        XCTAssertEqual(transition.targetFrame, custom)
    }
}
