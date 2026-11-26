import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfDropHandlerTests: XCTestCase {
    func testTutorialTokenAllowsAnInternalDropAndForcesCopy() {
        let notices = ShelfNoticeModel()
        let coordinator = DropImportCoordinator(
            bookmarkService: BookmarkService(), tempFileService: TempFileService(), noticeCenter: notices
        )
        coordinator.isActiveTutorialToken = { $0 == "active" }
        let handler = ShelfDropHandler(store: ShelfStore(), coordinator: coordinator, notices: notices)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([PasteboardTypes.fileURL, PasteboardTypes.tutorialSession], owner: nil)
        pasteboard.setString("file:///tmp/tutorial.txt", forType: PasteboardTypes.fileURL)
        pasteboard.setString("expired", forType: PasteboardTypes.tutorialSession)

        XCTAssertFalse(handler.accepts(pasteboard, isInternal: true))
        pasteboard.setString("active", forType: PasteboardTypes.tutorialSession)
        XCTAssertTrue(handler.accepts(pasteboard, isInternal: true))
        XCTAssertEqual(handler.mode(for: pasteboard, modifiers: [.command]), .copy)
    }

    func testSynchronousDropInsertsAtTheDestinationIndex() {
        let notices = ShelfNoticeModel()
        let coordinator = DropImportCoordinator(
            bookmarkService: BookmarkService(), tempFileService: TempFileService(), noticeCenter: notices
        )
        let existing = ShelfItem(kind: .text, displayName: "Existing", text: "Existing")
        let store = ShelfStore(items: [existing])
        let handler = ShelfDropHandler(store: store, coordinator: coordinator, notices: notices)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("New", forType: .string)

        XCTAssertTrue(handler.performDrop(from: pasteboard, isInternal: false, at: 0))
        XCTAssertEqual(store.items.map(\.text), ["New", "Existing"])
    }
}
