import XCTest
@testable import OpenYoink

@MainActor
final class IslandModuleLibraryLayoutTests: XCTestCase {
    func testPinnedDisplayUsesSavedOrderAndDoesNotRepeatInGroups() {
        let descriptors = IslandModuleRegistry().descriptors
        let layout = IslandModuleLibraryLayout(
            descriptors: Array(descriptors.reversed()),
            pinnedIDs: [.system, "future-module", .clipboard, .shelf]
        )

        XCTAssertEqual(layout.pinned.map(\.id), [.system, .clipboard, .shelf])
        XCTAssertEqual(layout.modules(in: .files).map(\.id), [.transfers, .folders])
        XCTAssertEqual(layout.modules(in: .productivity).map(\.id), [.timer, .media, .aiUsage])
        XCTAssertEqual(layout.modules(in: .system).map(\.id), [.battery])
    }
}
