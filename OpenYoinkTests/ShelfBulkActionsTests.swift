import Foundation
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfBulkActionsTests: XCTestCase {
    func testEnteringStackEndsTopLevelBulkMode() {
        let child = ShelfItem(kind: .text, displayName: "Child", text: "note")
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [child])
        let interaction = ShelfInteractionState()
        interaction.isSelecting = true
        interaction.enterStack(stack)
        XCTAssertFalse(interaction.isSelecting)
        XCTAssertEqual(interaction.expandedStackID, stack.id)
        XCTAssertEqual(interaction.focusedItemID, child.id)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-Bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testSelectAllVisibleReplacesHiddenSelectionAndKeepsDisplayOrder() {
        let files = (0..<600).map { ShelfItem(kind: .file, displayName: "Report \($0)") }
        let note = ShelfItem(kind: .text, displayName: "Note", text: "unrelated")
        let store = ShelfStore(items: files + [note])
        store.select(note.id)
        store.searchQuery = "Report"
        store.selectAllVisible()
        XCTAssertEqual(store.selectedItems.map(\.id), files.map(\.id))
        XCTAssertFalse(store.selection.contains(note.id))
        store.searchQuery = "missing"
        store.selectAllVisible()
        XCTAssertTrue(store.selection.isEmpty)
    }

    func testMixedBatchRemovalPreservesFilesAndUndoesAsOneOperation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try ["reference.txt", "managed.txt", "stack-child.txt"].enumerated().map { index, name in
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return ShelfItem(kind: .file, path: url.path, displayName: name, isCut: index > 0)
        }
        let stack = ShelfItem(kind: .stack, displayName: "Stack", children: [items[2]])
        let original = [items[0], stack, items[1]]
        let persistence = PersistenceController(directoryURL: root.appendingPathComponent("Data"))
        let store = ShelfStore(items: original, persistence: persistence)
        store.selectAllVisible()
        let removed = try store.removeBatchForUser(ids: store.selection)
        XCTAssertEqual(removed, original)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.undoProtectedPaths, Set(items.compactMap(\.path)))
        for item in items {
            XCTAssertEqual(try String(contentsOfFile: item.path!, encoding: .utf8), item.displayName)
        }
        let addedLater = ShelfItem(kind: .text, displayName: "New", text: "keep")
        store.add(addedLater)
        XCTAssertTrue(store.undoLastRemoval())
        XCTAssertEqual(store.items, original + [addedLater])
        XCTAssertFalse(store.canUndoRemoval)
        XCTAssertEqual(persistence.recoverySnapshots().filter { $0.kind == .removedItems }.count, 1)
    }

    func testClearIncludesFilteredItemsAndEmptyBatchCreatesNoArchive() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = ShelfItem(kind: .file, displayName: "Visible")
        let hidden = ShelfItem(kind: .text, displayName: "Hidden", text: "note")
        let persistence = PersistenceController(directoryURL: root)
        let store = ShelfStore(items: [visible, hidden], persistence: persistence)
        store.searchQuery = "Visible"
        XCTAssertTrue(try store.removeBatchForUser(ids: []).isEmpty)
        XCTAssertTrue(persistence.recoverySnapshots().isEmpty)
        let cleared = try store.removeBatchForUser(ids: Set(store.items.map(\.id)))
        XCTAssertEqual(cleared.map(\.id), [visible.id, hidden.id])
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.undoLastRemoval())
        XCTAssertEqual(store.items.map(\.id), [visible.id, hidden.id])
    }

    func testRecoveryWriteFailureLeavesItemsAndSelectionUntouched() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("NotADirectory")
        try Data("occupied".utf8).write(to: blocked)
        let persistence = PersistenceController(directoryURL: blocked)
        let item = ShelfItem(kind: .file, displayName: "Keep")
        let store = ShelfStore(items: [item], persistence: persistence)
        store.selectAllVisible()
        XCTAssertThrowsError(try store.removeBatchForUser(ids: store.selection))
        XCTAssertEqual(store.items, [item])
        XCTAssertEqual(store.selection, [item.id])
        XCTAssertFalse(store.canUndoRemoval)
    }
}
