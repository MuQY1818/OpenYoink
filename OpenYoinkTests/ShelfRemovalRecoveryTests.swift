import Foundation
import XCTest
@testable import OpenYoink

@MainActor
final class ShelfRemovalRecoveryTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-Removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFile(_ url: URL, isCut: Bool = false) throws -> ShelfItem {
        try Data("retained payload".utf8).write(to: url)
        return ShelfItem(kind: .file, path: url.path,
                         displayName: url.lastPathComponent,
                         addedAt: Date(timeIntervalSince1970: 1_700_000_000), isCut: isCut)
    }

    func testRemovalArchiveSurvivesEmptySavesAndRestartAndRestoresMixedShelf() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = TempFileService(directoryURL: root.appendingPathComponent("Materialized"))
        let external = try makeFile(root.appendingPathComponent("external.txt"))
        let managed = try makeFile(try temp.uniqueFileURL(suggestedName: "managed.txt"), isCut: true)
        let materialized = try makeFile(try temp.uniqueFileURL(suggestedName: "received.txt"))
        let stack = ShelfItem(kind: .stack, displayName: "Retained files",
                              addedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              children: [managed, materialized])
        let items = [external, stack]
        let persistence = PersistenceController(directoryURL: root)
        try persistence.saveNow(items)
        try persistence.saveRemovalRecoverySnapshot(items)
        try persistence.saveNow([])
        try persistence.saveNow([])

        let restarted = PersistenceController(directoryURL: root)
        XCTAssertTrue(restarted.load().isEmpty)
        let archive = try XCTUnwrap(restarted.recoverySnapshots().first { $0.kind == .removedItems })
        XCTAssertTrue(archive.isRecoverable)
        XCTAssertEqual(try restarted.loadRecoverySnapshot(archive), items)
        let protectedIDs = Set(DragPayloadBuilder.flattenedItems(restarted.recoverableSnapshotItems()).map(\.id))
        XCTAssertTrue(protectedIDs.isSuperset(of: [external.id, managed.id, materialized.id]))

        let store = ShelfStore(items: [], persistence: restarted)
        let storage = StorageManagementController(persistence: restarted, tempFileService: temp,
                                                   shelfStore: store)
        storage.restore(archive)

        XCTAssertNil(storage.errorMessage)
        XCTAssertEqual(store.items, items)
        XCTAssertEqual(restarted.load(), items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(managed.path)))
        XCTAssertTrue(restarted.recoverySnapshots().contains { $0.id == archive.id })
    }

    func testLegacyCompatibleRemovalArchiveProtectsCopiesUntilRecoveryDataIsDiscarded() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = TempFileService(directoryURL: root.appendingPathComponent("Materialized"))
        let external = try makeFile(root.appendingPathComponent("external.txt"))
        let managed = try makeFile(try temp.uniqueFileURL(suggestedName: "managed.txt"), isCut: true)
        let orphan = try temp.uniqueFileURL(suggestedName: "orphan.txt")
        try Data("unused".utf8).write(to: orphan)
        let persistence = PersistenceController(directoryURL: root)
        try persistence.saveRemovalRecoverySnapshot([external, managed])
        try persistence.saveNow([])
        try persistence.saveNow([])

        let restarted = PersistenceController(directoryURL: root)
        let archive = try XCTUnwrap(restarted.recoverySnapshots().first { $0.kind == .removedItems })
        XCTAssertTrue(archive.url.lastPathComponent.hasPrefix("shelf.json.corrupt-removed-"))
        // Version 1.8.1 blocks cleanup for any file with the quarantine prefix.
        // Preserve that contract while letting this version decode its archive.
        let legacyQuarantineNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("shelf.json.corrupt-") }
        XCTAssertTrue(legacyQuarantineNames.contains(archive.url.lastPathComponent))
        XCTAssertTrue(restarted.canSafelyCleanupMaterializedOrphans(after: restarted.loadResult()))
        let storage = StorageManagementController(persistence: restarted, tempFileService: temp,
                                                   shelfStore: ShelfStore())
        XCTAssertFalse(storage.hasQuarantinedData)
        XCTAssertTrue(storage.canCleanUnusedFiles)
        storage.cleanUnusedFiles()

        XCTAssertNil(storage.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(managed.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(external.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))

        storage.discardAllRecoveryData()
        XCTAssertNil(storage.errorMessage)
        XCTAssertTrue(restarted.recoverableSnapshotItems().isEmpty)
        storage.cleanUnusedFiles()

        XCTAssertNil(storage.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(managed.path)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(external.path)))
    }

    func testMultipleRemovalArchivesDoNotReplaceEachOther() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeFile(root.appendingPathComponent("first.txt"))
        let second = try makeFile(root.appendingPathComponent("second.txt"))
        let persistence = PersistenceController(directoryURL: root)
        try persistence.saveRemovalRecoverySnapshot([first])
        try persistence.saveRemovalRecoverySnapshot([second])

        let archives = persistence.recoverySnapshots().filter { $0.kind == .removedItems }
        XCTAssertEqual(archives.count, 2)
        XCTAssertEqual(Set(try archives.flatMap { try persistence.loadRecoverySnapshot($0).map(\.id) }),
                       [first.id, second.id])
    }

    func testDamagedRemovalArchiveBlocksStartupAndManualOrphanCleanup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let temp = TempFileService(directoryURL: root.appendingPathComponent("Materialized"))
        let managed = try makeFile(try temp.uniqueFileURL(suggestedName: "managed.txt"), isCut: true)
        let persistence = PersistenceController(directoryURL: root)
        try persistence.saveRemovalRecoverySnapshot([managed])
        let archive = try XCTUnwrap(persistence.recoverySnapshots().first { $0.kind == .removedItems })
        try Data("damaged archive".utf8).write(to: archive.url)
        try persistence.saveNow([])

        let restarted = PersistenceController(directoryURL: root)
        XCTAssertFalse(restarted.canSafelyCleanupMaterializedOrphans(after: restarted.loadResult()))
        let storage = StorageManagementController(persistence: restarted, tempFileService: temp,
                                                   shelfStore: ShelfStore())
        XCTAssertFalse(storage.canCleanUnusedFiles)
        XCTAssertFalse(try XCTUnwrap(storage.snapshots.first { $0.kind == .removedItems }).isRecoverable)
        storage.cleanUnusedFiles()

        XCTAssertNotNil(storage.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(managed.path)))
    }

    func testRemovalArchiveWriteFailureIsReportedWithoutChangingExistingData() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("not-a-directory")
        let original = Data("existing data".utf8)
        try original.write(to: blocker)
        let persistence = PersistenceController(directoryURL: blocker)

        XCTAssertThrowsError(try persistence.saveRemovalRecoverySnapshot([]))
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }

    func testRemovalArchiveOperationsRejectOutsideDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let other = PersistenceController(directoryURL: outside)
        try other.saveRemovalRecoverySnapshot([])
        let archive = try XCTUnwrap(other.recoverySnapshots().first)
        let persistence = PersistenceController(directoryURL: root)

        XCTAssertThrowsError(try persistence.loadRecoverySnapshot(archive))
        XCTAssertThrowsError(try persistence.discardRecoverySnapshot(archive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.url.path))
    }
}
