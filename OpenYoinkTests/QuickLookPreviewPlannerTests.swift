import XCTest
@testable import OpenYoink

/// Which items Quick Look shows (`QuickLookPreviewPlanner`, pure).
final class QuickLookPreviewPlannerTests: XCTestCase {
    // MARK: - Helpers

    private func file(_ name: String, stale: Bool = false) -> ShelfItem {
        var item = ShelfItem(kind: .file, path: "/tmp/\(name)", displayName: name)
        item.isStale = stale
        return item
    }

    private func stack(_ name: String, children: [ShelfItem]) -> ShelfItem {
        ShelfItem(kind: .stack, displayName: name, children: children)
    }

    private func ids(_ items: [ShelfItem]) -> [UUID] {
        items.map(\.id)
    }

    // MARK: - Base set rules (§2.3 Quick Look)

    /// Right-clicking a selected card previews the whole selection, in display order.
    func testContextItemInSelection_previewsWholeSelectionInDisplayOrder() {
        let a = file("a"), b = file("b"), c = file("c")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b, c], contextItem: b)
        XCTAssertEqual(ids(result), ids([a, b, c]))
    }

    /// Right-clicking an unselected card (or a stack child) previews only it.
    func testContextItemOutsideSelection_previewsContextItemOnly() {
        let a = file("a"), b = file("b")
        let context = file("x")
        let result = QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: context)
        XCTAssertEqual(ids(result), [context.id])
    }

    /// Space (no context item) previews the selection; nothing without one.
    func testNilContextItem_usesSelectionOrNothing() {
        let a = file("a"), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       ids([a, b]))
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [], contextItem: nil).isEmpty)
    }

    // MARK: - Stack flattening

    /// Stacks expand into their children (nested ones too), keeping order.
    func testStacksAreFlattenedRecursively() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3"), f4 = file("f4")
        let inner = stack("inner", children: [f2, f3])
        let outer = stack("outer", children: [f1, inner])
        let result = QuickLookPreviewPlanner.previewItems(selection: [outer, f4], contextItem: nil)
        XCTAssertEqual(ids(result), ids([f1, f2, f3, f4]))
    }

    /// A single selected stack as context previews its children, not the stack.
    func testContextStackExpandsToChildren() {
        let f1 = file("f1"), f2 = file("f2")
        let s = stack("s", children: [f1, f2])
        let result = QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: s)
        XCTAssertEqual(ids(result), ids([f1, f2]))
    }

    // MARK: - Stale filtering

    /// Unavailable items (Quick Look can't open them) are dropped, stack
    /// children included; all unavailable means an empty set (the panel stays closed).
    func testStaleItemsAreFilteredIncludingStackChildren() {
        let a = file("a", stale: true), b = file("b")
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [a, b], contextItem: nil)),
                       [b.id])

        let staleChild = file("c", stale: true), liveChild = file("d")
        let s = stack("s", children: [staleChild, liveChild])
        XCTAssertEqual(ids(QuickLookPreviewPlanner.previewItems(selection: [s], contextItem: nil)),
                       [liveChild.id])

        let allStale = stack("t", children: [file("e", stale: true)])
        XCTAssertTrue(QuickLookPreviewPlanner.previewItems(selection: [a, allStale], contextItem: nil).isEmpty)
    }

    // MARK: - Current index

    /// The start is the context item's position in the flattened set; 0 when absent.
    func testCurrentIndex() {
        let f1 = file("f1"), f2 = file("f2"), f3 = file("f3")
        let flattened = [f1, f2, f3]
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: f3), 2)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: file("other")), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: flattened, contextItem: nil), 0)
        XCTAssertEqual(QuickLookPreviewPlanner.currentIndex(in: [], contextItem: f1), 0)
    }
}
