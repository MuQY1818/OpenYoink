import XCTest
@testable import OpenYoink

final class EmptyShelfAutoHideTests: XCTestCase {
    func testNonEmptyToEmpty_whileVisible_requestsHide() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true)) // baseline
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testManuallySummonedEmptyShelf_neverHides() {
        // The user opens an empty shelf: the first evaluation only sets the
// baseline, and the following 0→0 changes don't trigger.
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testTransitionWhileHidden_doesNotFire_andKeepsBaselineFresh() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        // Emptied while hidden (Clear from the menu bar): nothing to hide; the
// baseline still updates.
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: false, isEnabled: true))
        // The user then opens the empty shelf: 0→0 doesn't trigger.
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testSettingDisabled_neverFires() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: false))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: false))
    }

    func testPartialRemoval_doesNotFire() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 3, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
    }

    func testEmptyThenRefilledThenEmptied_firesOnEachTransition() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true))
    }

    func testUserRemovalKeepsShelfOpenButLaterDeliveryStillHides() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false, isUserRemoval: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                    isDragInProgress: false))
    }

    /// Items go from >0 to 0 during a drag (another hand presses Delete): must
    /// not hide, or a cross-app drop hovering over the shelf would miss.
    func testDragInProgress_transitionToEmpty_isSuppressed() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // baseline
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
    }

    func testDragInProgress_suppressedHide_isNotReplayedAfterDragEnds() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true)) // suppressed; the baseline becomes 0
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: false)) // drag ended; 0→0 doesn't trigger
    }

    /// The gate only blocks during a drag: refilled and emptied again after it, it triggers.
    func testAfterDragEnds_ruleFiresNormally() {
        var rule = EmptyShelfAutoHideRule()
        XCTAssertFalse(rule.evaluate(itemCount: 2, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                     isDragInProgress: true))
        XCTAssertFalse(rule.evaluate(itemCount: 1, isVisible: true, isEnabled: true,
                                     isDragInProgress: false))
        XCTAssertTrue(rule.evaluate(itemCount: 0, isVisible: true, isEnabled: true,
                                    isDragInProgress: false))
    }
}
