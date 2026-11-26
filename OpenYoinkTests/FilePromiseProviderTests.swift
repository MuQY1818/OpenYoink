import AppKit
import Synchronization
import XCTest
@testable import OpenYoink

@MainActor
final class FilePromiseProviderTests: XCTestCase {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePayload(sourceURL: URL,
                             bookmark: Data? = nil,
                             suggestedName: String = "hello.txt",
                             promisedFileType: String = "public.plain-text") -> FilePromiseProvider.Payload {
        FilePromiseProvider.Payload(sourceURL: sourceURL,
                                    bookmark: bookmark,
                                    suggestedName: suggestedName,
                                    promisedFileType: promisedFileType)
    }

    // MARK: - writeCopy

    func testWriteCopy_copiesFileToDestination_andKeepsSource() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "promise content".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("drop-target/hello.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "promise content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "Writing a file promise must copy and preserve the source.")
    }

    func testWriteCopy_withBookmark_resolvesAndCopies() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bookmarked.txt")
        try "via bookmark".write(to: source, atomically: true, encoding: .utf8)
        let bookmark = try bookmarkService.createBookmark(for: source)
        let destination = directory.appendingPathComponent("out.txt")

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source, bookmark: bookmark),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "via bookmark")
    }

    func testWriteCopy_folder_copiesRecursively() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFolder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "nested".write(to: sourceFolder.appendingPathComponent("nested.txt"),
                           atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("docs-copy")

        try FilePromiseProvider.writeCopy(
            of: makePayload(sourceURL: sourceFolder,
                            suggestedName: "docs",
                            promisedFileType: "public.folder"),
            to: destination,
            bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("nested.txt"),
                                  encoding: .utf8), "nested")
    }

    func testWriteCopy_missingSource_throws() {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        let payload = makePayload(sourceURL: directory.appendingPathComponent("nonexistent.txt"))

        XCTAssertThrowsError(try FilePromiseProvider.writeCopy(
            of: payload,
            to: directory.appendingPathComponent("out.txt"),
            bookmarkService: bookmarkService))
    }

    // MARK: - Delegate

    func testDelegate_fileNameForType_returnsSuggestedName() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt"),
                                 suggestedName: "bg.txt"),
            bookmarkService: BookmarkService()
        )
        XCTAssertEqual(provider.delegate?.filePromiseProvider(provider, fileNameForType: "public.plain-text"),
                       "bg.txt")
    }

    func testDelegate_writePromiseTo_reportsPromiseRepresentationRequested() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        let requestCount = Mutex(0)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: source),
            bookmarkService: BookmarkService(),
            onPromiseRequested: { requestCount.withLock { $0 += 1 } }
        )

        _ = provider.delegate?.filePromiseProvider(provider, fileNameForType: "public.data")
        XCTAssertEqual(requestCount.withLock { $0 }, 0,
                       "A filename inquiry leaves the write unrequested.")
        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { _ in }

        XCTAssertEqual(requestCount.withLock { $0 }, 1)
    }

    func testDelegate_operationQueue_isUserInitiated() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let queue = provider.delegate?.operationQueue?(for: provider)
        XCTAssertEqual(queue?.qualityOfService, .userInitiated)
        XCTAssertFalse(queue === OperationQueue.main, "promise writes must not run on the main queue")
    }

    func testDelegate_methodsCallableFromBackgroundQueue() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/bg.txt"),
                                 suggestedName: "bg.txt"),
            bookmarkService: BookmarkService()
        )
        let delegate = provider.delegate
        DispatchQueue.global().sync {
            _ = delegate?.filePromiseProvider(provider, fileNameForType: "public.data")
            _ = delegate?.operationQueue?(for: provider)
        }
    }

    func testDelegate_writePromiseTo_successReportsNilError() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "delegate write".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.txt")
        let provider = FilePromiseProvider(payload: makePayload(sourceURL: source),
                                           bookmarkService: bookmarkService)

        // The delegate writes synchronously (AppKit calls it on the write queue in
        // a real session), so a direct call can assert the result.
        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "delegate write")
    }

    func testDelegate_writePromiseTo_failureReportsErrorWithoutCrashing() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingSource = directory.appendingPathComponent("nonexistent.txt")
        let reportedError = Mutex<Error?>(nil)
        let completionError = Mutex<Error??>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: missingSource),
            bookmarkService: bookmarkService,
            onError: { error in reportedError.withLock { $0 = error } }
        )

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNotNil(try XCTUnwrap(completionError.withLock { $0 }),
                        "A failed write must report the error to the receiving app.")
        XCTAssertNotNil(reportedError.withLock { $0 },
                        "A failed write must invoke onError.")
    }

    func testDirectFileWriter_serializesFileURLAndChromiumFilenameList() {
        let source = URL(fileURLWithPath: "/tmp/OpenYoink 示例.txt")
        let writer = DirectFilePasteboardWriter(fileURL: source)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertEqual(writer.writableTypes(for: pasteboard), [
            PasteboardTypes.fileURL,
            PasteboardTypes.legacyFilenames,
        ])
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.fileURL), source.absoluteString)
        XCTAssertEqual(
            pasteboard.propertyList(forType: PasteboardTypes.legacyFilenames) as? [String],
            [source.path]
        )
    }

    func testDirectFileWriter_serializesTutorialTokenIntoRealPasteboard() {
        let token = UUID().uuidString
        let writer = DirectFilePasteboardWriter(
            fileURL: URL(fileURLWithPath: "/tmp/tutorial.txt"),
            tutorialSessionToken: token
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertTrue(pasteboard.types?.contains(PasteboardTypes.tutorialSession) == true)
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.tutorialSession), token)
    }

    func testDirectFileWriter_tiffFallbackIsLazyUntilRequested() {
        let requestCount = Mutex(0)
        let expected = Data([0x49, 0x49, 0x2A, 0x00])
        let writer = DirectFilePasteboardWriter(
            fileURL: URL(fileURLWithPath: "/tmp/image.tiff"),
            tiffDataProvider: {
                requestCount.withLock { $0 += 1 }
                return expected
            }
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))

        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertEqual(requestCount.withLock { $0 }, 0,
                       "Populating the drag pasteboard must defer full image decoding.")
        XCTAssertEqual(pasteboard.data(forType: PasteboardTypes.tiff), expected)
        XCTAssertEqual(requestCount.withLock { $0 }, 1)
    }

    /// A managed cut item's provider only ever declares promise types.
    func testFilePromiseProvider_alwaysAdvertisesPromiseOnly() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        let types = provider.writableTypes(for: pasteboard)

        XCTAssertFalse(types.contains(.fileURL))
        XCTAssertFalse(types.contains(PasteboardTypes.legacyFilenames))
        XCTAssertFalse(types.contains(PasteboardTypes.tiff))
        XCTAssertFalse(types.contains(PasteboardTypes.tutorialSession))
        XCTAssertTrue(types.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })
    }

    /// The completion callback carries the destination URL (delivery confirmation).
    func testDelegate_writePromiseTo_successCallsOnDeliveredWithDestination() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "deliver me".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.txt")
        let deliveredURL = Mutex<URL?>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: source),
            bookmarkService: bookmarkService,
            onDelivered: { url in deliveredURL.withLock { $0 = url } }
        )

        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { _ in }

        XCTAssertEqual(deliveredURL.withLock { $0 }, destination)
    }

    /// A failed write doesn't confirm delivery (only onError).
    func testDelegate_writePromiseTo_failureDoesNotCallOnDelivered() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deliveredURL = Mutex<URL?>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: directory.appendingPathComponent("nonexistent.txt")),
            bookmarkService: bookmarkService,
            onDelivered: { url in deliveredURL.withLock { $0 = url } }
        )

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { _ in }

        XCTAssertNil(deliveredURL.withLock { $0 })
    }

}
