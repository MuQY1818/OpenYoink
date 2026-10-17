import XCTest
@testable import OpenYoink

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func testDownContinuesFromTabFocusedPaneRatherThanSelection() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .general

        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: .storage), .about)
        XCTAssertEqual(navigation.selectedPane, .about)
    }

    func testUpContinuesFromTabFocusedPaneRatherThanSelection() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .about

        XCTAssertEqual(navigation.moveSidebarSelection(forward: false, focusedPane: .triggers), .appearance)
        XCTAssertEqual(navigation.selectedPane, .appearance)
    }

    func testNoFocusedButtonFallsBackToSelectedPane() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .appearance

        XCTAssertEqual(navigation.moveSidebarSelection(forward: true, focusedPane: nil), .triggers)
        XCTAssertEqual(navigation.moveSidebarSelection(forward: false, focusedPane: nil), .appearance)
    }

    func testArrowsDoNotWrapAtSidebarBoundaries() {
        let navigation = SettingsNavigationModel()
        navigation.selectedPane = .general
        XCTAssertNil(navigation.moveSidebarSelection(forward: false, focusedPane: .general))
        XCTAssertEqual(navigation.selectedPane, .general)

        navigation.selectedPane = .about
        XCTAssertNil(navigation.moveSidebarSelection(forward: true, focusedPane: .about))
        XCTAssertEqual(navigation.selectedPane, .about)
    }
}
