import XCTest
@testable import OpenYoink

/// Whether a recent item can go back on the shelf (MenuBarController.canReadd).
final class MenuBarControllerTests: XCTestCase {
    private var temporaryFileURL: URL!

    override func setUpWithError() throws {
        temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)")
        try Data("fixture".utf8).write(to: temporaryFileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }

    private func entry(kind: ItemKind, path: String? = nil, urlString: String? = nil) -> RecentEntry {
        RecentEntry(item: ShelfItem(kind: kind,
                                    path: path,
                                    displayName: "Entry",
                                    urlString: urlString),
                    draggedOutAt: Date())
    }

    /// A file that still exists and is readable → can be re-added.
    func testFileEntryReaddsWhenReadable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .file, path: temporaryFileURL.path)))
    }

    /// A deleted or inaccessible file → disabled.
    func testFileEntryDisabledWhenUnreachable() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .file, path: "/nonexistent/gone-\(UUID().uuidString)")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .image, path: nil)))
    }

    /// A URL entry that parses → can be re-added.
    func testURLEntryReaddsWhenParseable() {
        XCTAssertTrue(MenuBarController.canReadd(entry(kind: .url, urlString: "https://example.com")))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .url, urlString: nil)))
    }

    /// Text keeps only a 100-character summary and stacks were expanded on
/// drag; neither can be restored faithfully, so both are disabled.
    func testTextAndStackEntriesAreDisabled() {
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .text)))
        XCTAssertFalse(MenuBarController.canReadd(entry(kind: .stack)))
    }
}
