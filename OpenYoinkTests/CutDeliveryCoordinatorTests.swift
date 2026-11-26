import Foundation
import XCTest
@testable import OpenYoink

@MainActor
final class DeliveryCoordinatorTests: XCTestCase {
    @MainActor
    private struct Context {
        let store: ShelfStore
        let recents: RecentItemsService
        let tempFileService: TempFileService
        let transferStore = TransferStore()
        let coordinator: DeliveryCoordinator
        var temporaryURLs: [URL] = []

        init(items: [ShelfItem] = []) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-CutDelivery-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            recents = RecentItemsService(directoryURL: root)
            store = ShelfStore(items: items)
            coordinator = DeliveryCoordinator(store: store,
                                              recents: recents,
                                              tempFileService: tempFileService,
                                              transferStore: transferStore)
            temporaryURLs.append(root)
        }

        func cleanup() {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext() -> Context { Context() }

    /// A real file in managed storage plus an isCut item pointing at it.
    private func makeCutItem(in context: inout Context, name: String = "cut-me.txt") throws -> ShelfItem {
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: name)
        try "managed content".write(to: managedURL, atomically: true, encoding: .utf8)
        return ShelfItem(kind: .file,
                         path: managedURL.path,
                         displayName: name,
                         isCut: true)
    }

    private func contents(for items: [ShelfItem]) -> DragOutContents {
        DragOutContents(items: items, topLevelIDs: Set(items.map(\.id)))
    }

    private func beginSession(_ context: Context, items: [ShelfItem]) -> UUID {
        let id = UUID()
        context.coordinator.noteSessionBegan(id: id, contents: contents(for: items))
        return id
    }

    /// A drag that never starts an AppKit session (no pasteboard writer could
    /// be built) must not leave the transfer strip hidden for good.
    func testUnstartedDragSessionDoesNotHideTransferStrip() {
        let context = makeContext()
        defer { context.cleanup() }
        let item = ShelfItem(kind: .text, displayName: "empty")
        let sessionID = beginSession(context, items: [item])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: false)
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 0)

        context.coordinator.noteDragSessionStarted()
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 1)
        context.coordinator.noteDragSessionEnded()
        XCTAssertEqual(context.transferStore.dragSessionsInFlight, 0)
    }

    func testDeliveryAfterSuccessfulSession_finalizesItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertNotNil(context.store.item(withID: item.id), "Keep the item until delivery is confirmed.")
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)

        XCTAssertNil(context.store.item(withID: item.id), "the item must leave the shelf after delivery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "Delete the managed copy after successful delivery.")
        let entry = try XCTUnwrap(context.recents.entries.first)
        XCTAssertEqual(entry.displayName, item.displayName)
        XCTAssertEqual(entry.path, destination.path, "history records the destination path (the managed copy is gone)")
    }

    /// Reversed: the promise is written before the session ends (a small file)
/// → finalized when the session succeeds.
    func testDeliveryBeforeSessionEnd_finalizesOnSessionEnd() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("delivered-\(UUID().uuidString).txt")
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: destination)
        XCTAssertNotNil(context.store.item(withID: item.id), "Keep the item until the drag session succeeds.")
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertEqual(context.recents.entries.first?.path, destination.path)
    }

    /// Cancel (operation == []): item and managed file stay; the pending state clears.
    func testCancelledSession_keepsItemAndManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: false)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        XCTAssertTrue(context.recents.entries.isEmpty)
        // Defensive: a late, unexpected delivery after cancel changes nothing.
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/x.txt"))
        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
    }

    /// Delivery failed: item and managed file stay (retryable); the strip shows
/// the real failure.
    func testDeliveryFailure_keepsItemAndShowsTransferFailure() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)

        XCTAssertNotNil(context.store.item(withID: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL!.path))
        if case .failed(let failure) = context.transferStore.currentTask?.phase {
            XCTAssertEqual(failure.reason, .deliveryFailed)
            XCTAssertEqual(failure.recoveryAction, .retryByDraggingOut(itemID: item.id))
        } else {
            XCTFail("a failed delivery must enter the failed state")
        }
        XCTAssertTrue(context.recents.entries.isEmpty)
    }

    /// A cut item inside a stack: removed from the stack after delivery (a
/// child drag has no top-level IDs).
    func testCutChildInStack_removedFromStackOnDelivery() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let cutChild = try makeCutItem(in: &context, name: "child.txt")
        let sibling = ShelfItem(kind: .file, path: "/tmp/sibling.txt", displayName: "sibling.txt")
        let stack = ShelfItem(kind: .stack, displayName: "child.txt", children: [cutChild, sibling])
        context.store.add(stack)
        // A child dragged from the overlay: no top-level IDs (the stack itself stays).
        let childContents = DragOutContents(items: [cutChild], topLevelIDs: [])
        let sessionID = UUID()
        context.coordinator.noteSessionBegan(id: sessionID, contents: childContents)

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: cutChild.id,
                                          destination: URL(fileURLWithPath: "/tmp/out-child.txt"))

        XCTAssertNil(context.store.item(withID: stack.id), "a stack with one child left dissolves")
        let survivor = try XCTUnwrap(context.store.items.first)
        XCTAssertEqual(survivor.id, sibling.id, "the surviving child stays in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutChild.fileURL!.path))
    }

    /// The user removed the item before delivery arrived: the managed file is
/// still deleted, nothing crashes, history is recorded.
    func testDeliveryAfterManualRemoval_stillDeletesManagedFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let item = try makeCutItem(in: &context)
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        context.store.remove(ids: [item.id]) // the user removes it
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/out.txt"))

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL!.path),
                       "The item snapshot drives finalization even after the card is removed.")
        XCTAssertEqual(context.recents.entries.first?.displayName, item.displayName)
    }

    /// A plain file without a promise request can only report "accepted".
    func testOrdinaryDirectRepresentationReportsTargetAccepted() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let normal = ShelfItem(kind: .file, path: "/tmp/normal.txt", displayName: "normal.txt")
        context.store.add(normal)
        let sessionID = beginSession(context, items: [normal])

        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNotNil(context.store.item(withID: normal.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
        XCTAssertTrue(context.recents.entries.isEmpty, "plain items' history is recorded by DragSessionController's policy path")
    }

    func testAcceptedDirectMaterializedItemProtectsRuntimeLeaseAfterRemoval() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let managedURL = try context.tempFileService.uniqueFileURL(suggestedName: "kept.txt")
        try "only copy".write(to: managedURL, atomically: true, encoding: .utf8)
        let item = ShelfItem(kind: .file,
                             path: managedURL.path,
                             displayName: "kept.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)
        XCTAssertTrue(context.coordinator.protectedMaterializedPaths.contains(managedURL.path))
    }

    /// Plain items carry no file promise; even an unexpected late callback must
    /// not reinsert an item the user's policy removed or fake a failure.
    func testDirectItemIgnoresSpuriousPromiseCallbacks() {
        let context = makeContext()
        defer { context.cleanup() }
        let item = ShelfItem(kind: .file, path: "/tmp/direct.txt", displayName: "direct.txt")
        context.store.add(item)
        let sessionID = beginSession(context, items: [item])

        context.coordinator.notePromiseRequested(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteFailed(sessionID: sessionID, itemID: item.id)
        context.coordinator.noteDelivered(sessionID: sessionID,
                                          itemID: item.id,
                                          destination: URL(fileURLWithPath: "/tmp/unexpected.txt"))
        context.store.remove(ids: [item.id])
        context.coordinator.noteSessionEnded(id: sessionID, accepted: true)

        XCTAssertNil(context.store.item(withID: item.id))
        XCTAssertEqual(context.transferStore.currentTask?.phase, .targetAccepted)
    }
}
