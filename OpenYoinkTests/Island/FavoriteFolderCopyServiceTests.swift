import XCTest
@testable import OpenYoink

final class FavoriteFolderCopyServiceTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenYoinkCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testCopyAndKeepBothNeverOverwriteOrDeleteOriginal() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("note.txt")
        try Data("new".utf8).write(to: file)
        try Data("existing".utf8).write(to: target.appendingPathComponent("note.txt"))
        let bookmarks = BookmarkService()
        let service = FavoriteFolderCopyService(bookmarks: bookmarks)
        let result = await service.copy([try bookmarks.createBookmark(for: file)], to: try bookmarks.createBookmark(for: target),
                                        conflict: { _ in .keepBoth }, progress: { _, _ in })
        XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("note.txt"), encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("note (2).txt"), encoding: .utf8), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: target.path).contains { $0.hasPrefix(".openyoink-copy-") })
    }
    func testSkipAndCancelKeepSourceAndDestination() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a")
        try Data("original".utf8).write(to: file)
        let bookmarks = BookmarkService()
        let service = FavoriteFolderCopyService(bookmarks: bookmarks)
        let sources = [try bookmarks.createBookmark(for: file), try bookmarks.createBookmark(for: file)]
        let destination = try bookmarks.createBookmark(for: root)
        let skipped = await service.copy(sources, to: destination, conflict: { _ in .skip }, progress: { _, _ in })
        XCTAssertEqual(skipped.skipped, 2)
        let cancelled = await service.copy(sources, to: destination, conflict: { _ in .cancel }, progress: { _, _ in })
        XCTAssertEqual(cancelled.cancelled, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
    func testDirectoryCannotBeCopiedIntoItselfOrSymlinkedDescendant() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertFalse(FavoriteFolderCopyService.isSafeDestination(root, for: root))
        XCTAssertFalse(FavoriteFolderCopyService.isSafeDestination(child, for: root))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        XCTAssertFalse(FavoriteFolderCopyService.isSafeDestination(alias, for: root))
        let bookmarks = BookmarkService()
        let result = await FavoriteFolderCopyService(bookmarks: bookmarks).copy(
            [try bookmarks.createBookmark(for: root)], to: try bookmarks.createBookmark(for: child),
            conflict: { _ in .keepBoth }, progress: { _, _ in })
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: child.path).isEmpty)
    }
}
