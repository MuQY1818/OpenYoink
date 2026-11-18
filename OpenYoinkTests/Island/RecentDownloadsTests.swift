import XCTest
@testable import OpenYoink

@MainActor
final class RecentDownloadsTests: XCTestCase {
    private struct Fixture {
        let folder: URL
        let suite: String
        let defaults: UserDefaults
        let bookmarks = BookmarkService()

        init() throws {
            suite = "OpenYoinkTests.RecentDownloads.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        @discardableResult
        func makeFile(_ name: String) throws -> URL {
            let file = folder.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: file)
            return file
        }
    }

    func testScannerOnlyListsCompletedRegularFilesAtTopLevel() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.makeFile("notes.txt")
        for name in [".hidden", "image.CRDOWNLOAD", "image.download", "video.part", "audio.partial", "copy.tmp"] {
            try fixture.makeFile(name)
        }
        let nested = fixture.folder.appendingPathComponent("subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.makeFile("subfolder/nested.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.folder.appendingPathComponent("link.txt"), withDestinationURL: file
        )

        let entries = try RecentDownloadsScanner.scan(fixture.folder)
        XCTAssertEqual(entries.map(\.url.lastPathComponent), ["notes.txt"])
    }

    func testScannerReturnsOnlyNewestEntriesInDisplayOrder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for index in 0..<17 {
            try fixture.makeFile("file-\(String(format: "%02d", index)).txt")
        }
        let all = try RecentDownloadsScanner.scan(fixture.folder, limit: 17)
        let capped = try RecentDownloadsScanner.scan(fixture.folder)
        XCTAssertEqual(all.count, 17)
        XCTAssertEqual(capped.count, 15)
        XCTAssertEqual(capped, Array(all.prefix(15)))
        for (first, second) in zip(all, all.dropFirst()) {
            XCTAssertTrue(first.date > second.date || (first.date == second.date && first.url.path < second.url.path))
        }
    }

    func testRestoredFolderAndShelfItemBookmarksAreIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.makeFile("notes.txt")
        let store = RecentDownloadsStore(defaults: fixture.defaults, bookmarks: fixture.bookmarks)
        try store.chooseFolder(fixture.folder)

        let restored = RecentDownloadsStore(defaults: fixture.defaults, bookmarks: fixture.bookmarks)
        await restored.refresh()
        XCTAssertEqual(restored.phase, .ready)
        let entry = try XCTUnwrap(restored.entries.first)
        let item = try XCTUnwrap(restored.makeShelfItem(entry))
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, "notes.txt")
        restored.forgetFolder()

        XCTAssertNil(fixture.defaults.data(forKey: RecentDownloadsStore.bookmarkKey))
        let resolved = try fixture.bookmarks.resolve(XCTUnwrap(item.bookmark))
        XCTAssertEqual(resolved.url.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: file), Data("fixture".utf8))
    }

    func testUnreadableBookmarkRemainsUntilUserChoosesOrForgetsFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let corrupted = Data("not a bookmark".utf8)
        fixture.defaults.set(corrupted, forKey: RecentDownloadsStore.bookmarkKey)
        let store = RecentDownloadsStore(defaults: fixture.defaults, bookmarks: fixture.bookmarks)

        await store.refresh()

        XCTAssertEqual(store.phase, .unavailable)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.bookmark, corrupted)
        XCTAssertEqual(fixture.defaults.data(forKey: RecentDownloadsStore.bookmarkKey), corrupted)
    }

    func testStaleEntryCannotOpenOrAddMissingFileOrReplacementSymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.makeFile("notes.txt")
        let store = RecentDownloadsStore(defaults: fixture.defaults, bookmarks: fixture.bookmarks)
        try store.chooseFolder(fixture.folder)
        await store.refresh()
        let entry = try XCTUnwrap(store.entries.first)

        try FileManager.default.removeItem(at: file)
        XCTAssertNil(try store.makeShelfItem(entry))
        let target = try fixture.makeFile("different.txt")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertNil(store.withFile(entry) { url in url })
        XCTAssertNil(try store.makeShelfItem(entry))
    }

    func testChangingFolderCancelsObsoleteRefreshEvenIfWorkerReturnsAResult() async throws {
        let old = try Fixture()
        defer { old.cleanup() }
        let new = try Fixture()
        defer { new.cleanup() }
        let oldEntry = RecentDownload(url: try old.makeFile("old.txt"), date: .distantPast)
        let newEntry = RecentDownload(url: try new.makeFile("new.txt"), date: .distantPast)
        let oldStarted = expectation(description: "old refresh entered worker")
        let oldCancelled = expectation(description: "old worker cancelled")
        let gate = AsyncStream<Void>.makeStream()
        let bookmarks = old.bookmarks
        let oldFolderName = old.folder.lastPathComponent
        let store = RecentDownloadsStore(defaults: old.defaults, bookmarks: bookmarks) { data in
            let folder = try bookmarks.resolve(data).url
            if folder.lastPathComponent == oldFolderName {
                return await withTaskCancellationHandler {
                    oldStarted.fulfill()
                    for await _ in gate.stream {}
                    return (folder, [oldEntry])
                } onCancel: {
                    oldCancelled.fulfill()
                }
            }
            return (folder, [newEntry])
        }
        try store.chooseFolder(old.folder)
        let oldRefresh = Task { await store.refresh() }
        defer { gate.continuation.finish() }
        await fulfillment(of: [oldStarted], timeout: 5)

        try store.chooseFolder(new.folder)
        await store.refresh()
        await fulfillment(of: [oldCancelled], timeout: 5)
        await oldRefresh.value

        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.entries, [newEntry])
        XCTAssertNil(store.withFile(oldEntry) { $0 })
    }
}
