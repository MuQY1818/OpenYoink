import AppKit
import Synchronization
import XCTest
@testable import OpenYoink

@MainActor
final class CutMoveServiceTests: XCTestCase {
    /// Per-test fixtures, built in place and cleaned up with defer (like
    /// DropImportCoordinatorTests, no setUp/tearDown).
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        /// The simulated app container (moves from inside it are refused).
        let containerURL: URL
        var temporaryURLs: [URL] = []

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-CutMove-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: root.appendingPathComponent("Materialized", isDirectory: true))
            containerURL = root.appendingPathComponent("Container", isDirectory: true)
            temporaryURLs.append(root)
        }

        func cleanup() {
            bookmarkService.stopAccessingAll()
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private func makeContext() -> Context { Context() }

    /// A source file or folder outside the container (in the temporary directory).
    private func makeSourceFile(in context: inout Context, named name: String = "sample.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-\(name)")
        try "sample content".write(to: url, atomically: true, encoding: .utf8)
        context.temporaryURLs.append(url)
        return url
    }

    private func makeService(context: Context,
                             trashOriginal: @escaping @Sendable (URL) throws -> Void) -> CutMoveService {
        CutMoveService(
            tempFileService: context.tempFileService,
            bookmarkService: context.bookmarkService,
            containerURL: context.containerURL,
            trashOriginal: trashOriginal
        )
    }

    private func managedDirectoryContents(_ context: Context) throws -> [String] {
        let directory = context.tempFileService.directoryURL
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func testMakeCutItem_success_copiesToManagedDirAndTrashesOriginal() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "notes.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "notes.txt")

        guard case .moved(let item) = outcome else {
            return XCTFail("Expected .moved, got \(outcome)")
        }
        XCTAssertTrue(item.isCut)
        XCTAssertEqual(item.displayName, "notes.txt", "displayName keeps the original name (no UUID prefix)")
        XCTAssertEqual(item.kind, .file)
        XCTAssertNotNil(item.bookmark, "the bookmark should point at the managed copy")
        // The copy is in place with identical content.
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path),
                      "The managed copy should be under Materialized: \(path)")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), "sample content")
        // The original went to the "Trash" (the mock deletes it), trashed once after the copy.
        XCTAssertEqual(trashed.withLock { $0 }, [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the original location should be gone")
        guard case .loaded(let records) = service.managedMoveJournal.loadResult() else {
            return XCTFail("Keep the recovery record after trashing the original.")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].state, .originalTrashed)
        XCTAssertEqual(records[0].managedItem.id, item.id)
    }

    func testMakeCutItem_folder_movesRecursively() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-docs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".write(to: folder.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        context.temporaryURLs.append(folder)
        let service = makeService(context: context) { url in
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: folder, displayName: "docs")

        guard case .moved(let item) = outcome else {
            return XCTFail("Expected .moved, got \(outcome)")
        }
        XCTAssertEqual(item.kind, .folder)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("inner.txt"),
                                  encoding: .utf8), "nested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testMakeCutItem_copyFailure_keepsOriginalAndFallsBack() throws {
        let context = makeContext()
        defer { context.cleanup() }
        // A missing source → copyItem throws.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-ghost.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: missing, displayName: "ghost.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .copyFailed)
        XCTAssertFalse(item.isCut, "the fallback is a plain reference")
        XCTAssertEqual(item.path, missing.path)
        XCTAssertEqual(trashed.withLock { $0 }, [], "A failed copy must leave the original untouched.")
        XCTAssertEqual(try managedDirectoryContents(context), [], "A failed copy must leave no partial managed copy.")
    }

    func testMakeCutItem_trashFailure_removesCopyAndFallsBack() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "readonly.txt")
        struct TrashRefused: Error {}
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            throw TrashRefused()
        }

        let outcome = service.makeCutItem(for: source, displayName: "readonly.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .trashFailed)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "The fallback reference points to the original.")
        XCTAssertEqual(trashed.withLock { $0 }, [source], "trash was attempted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "A failed trash operation must leave the original in place.")
        XCTAssertEqual(try managedDirectoryContents(context), [], "The managed copy must be removed.")
        XCTAssertEqual(service.managedMoveJournal.loadResult(), .missing,
                       "A failed trash operation must clear the recovery record.")
    }

    func testMakeCutItem_damagedJournalNeverTrashesOriginal() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "protected.txt")
        let root = context.tempFileService.directoryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("damaged".utf8).write(to: root.appendingPathComponent("managed-moves.json"))
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "protected.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .transactionFailed)
        XCTAssertEqual(item.path, source.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(trashed.withLock { $0 }, [])
        XCTAssertEqual(try managedDirectoryContents(context), [])
    }

    func testMakeCutItem_sourceInsideContainer_rejected() throws {
        let context = makeContext()
        defer { context.cleanup() }
        // The source is inside the "container".
        let container = context.containerURL
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let source = container.appendingPathComponent("already-ours.txt")
        try "inside".write(to: source, atomically: true, encoding: .utf8)
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }

        let outcome = service.makeCutItem(for: source, displayName: "already-ours.txt")

        guard case .fallbackToReference(let item, let reason) = outcome else {
            return XCTFail("Expected .fallbackToReference, got \(outcome)")
        }
        XCTAssertEqual(reason, .sourceInsideContainer)
        XCTAssertFalse(item.isCut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The source inside the container stays in place.")
        XCTAssertEqual(trashed.withLock { $0 }, [], "Refusing a managed move must skip trash.")
        XCTAssertEqual(try managedDirectoryContents(context), [], "Refusing a managed move must leave no copy.")
    }

    func testDropMode_commandWithFileURL_isMove() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .command), .move)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: [.command, .option]), .move,
                       "Command still selects move alongside other modifiers.")
    }

    func testDropMode_withoutCommand_isCopy() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: []), .copy)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: pasteboard, modifiers: .option), .copy,
                       "Option leaves the drop in copy mode.")
    }

    func testDropMode_commandWithNonFileContent_isCopy() {
        let text = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        text.writeObjects(["hello" as NSString])
        XCTAssertEqual(DropImportCoordinator.dropMode(for: text, modifiers: .command), .copy,
                       "Command leaves a text drop in copy mode.")

        let url = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        url.declareTypes([PasteboardTypes.url], owner: nil)
        url.setString("https://www.apple.com", forType: PasteboardTypes.url)
        XCTAssertEqual(DropImportCoordinator.dropMode(for: url, modifiers: .command), .copy,
                       "Command leaves a web URL drop in copy mode.")
    }

    func testImport_moveMode_perFileIndependentOutcomes() async throws {
        var context = makeContext()
        defer { context.cleanup() }
        let movable = try makeSourceFile(in: &context, named: "movable.txt")
        let stuck = try makeSourceFile(in: &context, named: "stuck.txt")
        struct TrashRefused: Error {}
        let noticeCenter = ShelfNoticeModel()
        let service = CutMoveService(
            tempFileService: context.tempFileService,
            bookmarkService: context.bookmarkService,
            containerURL: context.containerURL,
            trashOriginal: { url in
                if url.lastPathComponent.contains("stuck") {
                    throw TrashRefused()
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            noticeCenter: noticeCenter,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([movable as NSURL, stuck as NSURL])

        var received: [ShelfItem] = []
        let completion = expectation(description: "both background managed moves finish")
        completion.expectedFulfillmentCount = 2
        let collect: @MainActor (ShelfItem) -> Void = { item in
            received.append(item)
            completion.fulfill()
        }
        let result = coordinator.importItems(
            from: pasteboard,
            mode: .move,
            onManagedMoveReady: { item in
                collect(item)
                return true
            },
            onAsyncItemReady: collect
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.pendingMaterializations, 2)
        await fulfillment(of: [completion], timeout: 3)

        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received[0].isCut, "the one that trashed is moved in")
        XCTAssertFalse(received[1].isCut, "the one that failed to trash becomes a reference")
        XCTAssertEqual(received[1].path, stuck.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stuck.path), "the failed file stays as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movable.path), "the moved file's original location is gone")
        guard case .partiallySucceeded(let successCount, let failures) =
            coordinator.transferStore.currentTask?.phase else {
            return XCTFail("A managed move fallback should produce an actionable batch warning.")
        }
        XCTAssertEqual(successCount, 2, "both the moved item and the safe fallback reference joined the shelf")
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].reason, .managedMoveFellBackToReference)
        XCTAssertNil(noticeCenter.message, "batch status is shown by the activity strip alone, no duplicate notice")
    }

    func testImport_copyMode_neverCuts() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "keepme.txt")
        let trashed = Mutex<[URL]>([])
        let service = makeService(context: context) { url in
            trashed.withLock { $0.append(url) }
            try FileManager.default.removeItem(at: url)
        }
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([source as NSURL])

        let result = coordinator.importItems(from: pasteboard, mode: .copy) { _ in }

        let item = try XCTUnwrap(result.items.first)
        XCTAssertFalse(item.isCut)
        XCTAssertEqual(item.path, source.path, "Copy mode stores a reference to the original.")
        XCTAssertEqual(trashed.withLock { $0 }, [], "Copy mode skips trash.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Copy mode leaves the original in place.")
    }

    func testImport_moveMode_persistenceFailureBecomesRecoveryWarning() async throws {
        var context = makeContext()
        defer { context.cleanup() }
        let source = try makeSourceFile(in: &context, named: "needs-recovery.txt")
        let service = makeService(context: context) { url in
            try FileManager.default.removeItem(at: url)
        }
        let coordinator = DropImportCoordinator(
            bookmarkService: context.bookmarkService,
            tempFileService: context.tempFileService,
            cutMoveService: service
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        pasteboard.writeObjects([source as NSURL])
        let callback = expectation(description: "managed item reached persistence boundary")

        coordinator.importItems(
            from: pasteboard,
            mode: .move,
            onManagedMoveReady: { _ in
                callback.fulfill()
                return false
            },
            onAsyncItemReady: { _ in XCTFail("successful move should use managed callback") }
        )
        await fulfillment(of: [callback], timeout: 3)

        guard case .partiallySucceeded(let successCount, let failures) =
            coordinator.transferStore.currentTask?.phase else {
            return XCTFail("A failed immediate save must leave a recoverable warning.")
        }
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(failures.first?.reason, .persistenceFailed)
        XCTAssertEqual(failures.first?.impact, .itemAddedWithWarning)
        XCTAssertEqual(failures.first?.recoveryAction, .openStorageRecovery)
    }
}
