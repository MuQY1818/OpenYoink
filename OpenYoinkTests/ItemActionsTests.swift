import XCTest
@testable import OpenYoink

/// Availability rules of item operations (`ItemActions.canX`, pure): the
/// basis for disabled menu items and the "File Unavailable" branch.
@MainActor
final class ItemActionsTests: XCTestCase {
    // MARK: - Helpers

    private func item(_ kind: ItemKind,
                      path: String? = nil,
                      text: String? = nil,
                      urlString: String? = nil,
                      children: [ShelfItem]? = nil,
                      stale: Bool = false) -> ShelfItem {
        var result = ShelfItem(kind: kind, path: path, displayName: "item",
                               text: text, urlString: urlString, children: children)
        result.isStale = stale
        return result
    }

    // MARK: - Open

    func testCanOpen() {
        // Files, folders, images need a path; a folder opens (in Finder).
        XCTAssertTrue(ItemActions.canOpen(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canOpen(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canOpen(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canOpen(item(.file)))
        // Text opens as a temporary .txt and needs content.
        XCTAssertTrue(ItemActions.canOpen(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canOpen(item(.text, text: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.text)))
        // A URL opens with NSWorkspace and must parse.
        XCTAssertTrue(ItemActions.canOpen(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canOpen(item(.url, urlString: "")))
        XCTAssertFalse(ItemActions.canOpen(item(.url)))
        // Stacks can't be opened.
        XCTAssertFalse(ItemActions.canOpen(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // Never for an unavailable item.
        XCTAssertFalse(ItemActions.canOpen(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Show in Finder

    func testCanRevealInFinder() {
        // Files, folders, images reveal their resolved URL.
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file)))
        // Text reveals its temporary .txt.
        XCTAssertTrue(ItemActions.canRevealInFinder(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.text)))
        // A URL has no local file and a stack no single one: unavailable.
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.stack, children: [item(.file, path: "/tmp/a")])))
        // Never for an unavailable item.
        XCTAssertFalse(ItemActions.canRevealInFinder(item(.file, path: "/tmp/a.txt", stale: true)))
    }

    // MARK: - Quick Look

    func testCanQuickLook() {
        // Files, folders, images need an available path (Quick Look handles folders).
        XCTAssertTrue(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.folder, path: "/tmp")))
        XCTAssertTrue(ItemActions.canQuickLook(item(.image, path: "/tmp/a.png")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.file)))
        // Text previews as a temporary .txt and needs content.
        XCTAssertTrue(ItemActions.canQuickLook(item(.text, text: "hello")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.text, text: "")))
        // A URL previews as a temporary .txt of its string, which it needs.
        XCTAssertTrue(ItemActions.canQuickLook(item(.url, urlString: "https://example.com")))
        XCTAssertFalse(ItemActions.canQuickLook(item(.url)))
        // A stack needs one previewable child (recursively).
        let liveStack = item(.stack, children: [item(.file, path: "/tmp/a", stale: true),
                                                item(.stack, children: [item(.text, text: "hi")])])
        XCTAssertTrue(ItemActions.canQuickLook(liveStack))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [item(.file, path: "/tmp/a", stale: true)])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack, children: [])))
        XCTAssertFalse(ItemActions.canQuickLook(item(.stack)))
        // Never for an unavailable item.
        XCTAssertFalse(ItemActions.canQuickLook(item(.file, path: "/tmp/a.txt", stale: true)))
    }
}
