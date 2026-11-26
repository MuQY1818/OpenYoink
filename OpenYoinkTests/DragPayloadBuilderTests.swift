import AppKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// `registeredTypeIdentifiers`
@MainActor
final class DragPayloadBuilderTests: XCTestCase {
    private let bookmarkService = BookmarkService()

    // MARK: - Helpers

    private func makeItem(kind: ItemKind, name: String = "item") -> ShelfItem {
        switch kind {
        case .file, .folder, .image:
            ShelfItem(kind: kind, path: "/tmp/\(name)", displayName: name)
        case .text:
            ShelfItem(kind: .text, displayName: name, text: "sample text")
        case .url:
            ShelfItem(kind: .url, displayName: name, urlString: "https://example.com")
        case .stack:
            ShelfItem(kind: .stack, displayName: name, children: [
                ShelfItem(kind: .file, path: "/tmp/child-a.txt", displayName: "child-a.txt"),
            ])
        }
    }

    /// Writes the writer to a test pasteboard and returns its advertised types.
    private func advertisedTypes(of writer: NSPasteboardWriting) -> [String] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        guard pasteboard.writeObjects([writer]) else { return [] }
        return pasteboard.types?.map(\.rawValue) ?? []
    }

    /// Writes the writer to a test pasteboard and returns it, for reading data
    /// back the way a destination would.
    private func writtenPasteboard(for writer: NSPasteboardWriting) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        precondition(pasteboard.writeObjects([writer]), "the writer must write to the pasteboard")
        return pasteboard
    }

    func testStrategy_kindMapping() {
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .file)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .folder)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .image)), .fileBackedImage)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .text)), .plainText)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .url)), .webURL)
        XCTAssertNil(DragPayloadBuilder.strategy(for: makeItem(kind: .stack)),
                     "Dragging a stack exports its members.")
    }

    func testCanMakePasteboardWriterRejectsMalformedCards() {
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .file, displayName: "missing-path")
        ))
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "empty", text: "")
        ))
        XCTAssertFalse(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "bad", urlString: nil)
        ))
        XCTAssertTrue(DragPayloadBuilder.canMakePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "ok", text: "hello")
        ))
    }

    func testFlattenedItems_expandsStacksPreservingOrder() {
        let a = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        let b = ShelfItem(kind: .text, displayName: "b", text: "b")
        let c = ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com")
        let d = ShelfItem(kind: .file, path: "/tmp/d.txt", displayName: "d.txt")
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [b, c])

        let flat = [a, stack, d].flattened

        XCTAssertEqual(flat.map(\.displayName), ["a.txt", "b", "c", "d.txt"])
        XCTAssertEqual(flat.map(\.id), [a.id, b.id, c.id, d.id])
    }

    func testFlattenedItems_nestedStackAndEmptyStack() {
        let leaf = ShelfItem(kind: .file, path: "/tmp/leaf.txt", displayName: "leaf.txt")
        let inner = ShelfItem(kind: .stack, displayName: "inner", children: [leaf])
        let outer = ShelfItem(kind: .stack, displayName: "outer", children: [inner])
        let empty = ShelfItem(kind: .stack, displayName: "empty", children: [])

        let flat = [outer, empty].flattened
        XCTAssertEqual(flat.map(\.displayName), ["leaf.txt", "empty"])
    }

    func testPromisedFileType_folderExtensionFallback() {
        let folder = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: folder), UTType.folder.identifier)

        let text = ShelfItem(kind: .file, path: "/tmp/notes.txt", displayName: "notes.txt")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: text),
                       UTType(filenameExtension: "txt")?.identifier)

        let pdf = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: pdf),
                       UTType(filenameExtension: "pdf")?.identifier)

        let png = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: png),
                       UTType(filenameExtension: "png")?.identifier)

        let noExtension = ShelfItem(kind: .file, path: "/tmp/README", displayName: "README")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noExtension), UTType.data.identifier)

        let noPath = ShelfItem(kind: .file, displayName: "ghost")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noPath), UTType.data.identifier)
    }

    /// NSFilePromiseProvider raises an uncatchable NSException for an invalid
    /// fileType, so promisedFileType must conform to data or directory.
    func testPromisedFileType_alwaysConformsToDataOrDirectory() {
        let samples = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .file, path: "/tmp/a.pdf", displayName: "a.pdf"),
            ShelfItem(kind: .image, path: "/tmp/a.png", displayName: "a.png"),
            ShelfItem(kind: .file, path: "/tmp/a.unknownext123", displayName: "a.unknownext123"),
            ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs"),
            ShelfItem(kind: .file, path: "/tmp/README", displayName: "README"),
        ]
        for item in samples {
            let identifier = DragPayloadBuilder.promisedFileType(for: item)
            let type = UTType(identifier)
            XCTAssertNotNil(type, "\(identifier) must be a declared UTI")
            XCTAssertTrue(type?.conforms(to: .data) == true || type?.conforms(to: .directory) == true,
                          "NSFilePromiseProvider requires \(identifier) to conform to data or directory.")
        }
    }

    func testFileItem_writerAdvertisesFileURLAndChromiumFilenameList() throws {
        let item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter,
                        "Regular files must use a direct writer that preserves every advertised type during a drag.")

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier),
                      "Finder copy requires public.file-url in \(advertised).")
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue),
                      "Chromium requires filenames in \(advertised).")
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) },
                       "A regular file must use a writer that keeps supplementary types during drags.")

        XCTAssertEqual(writer.pasteboardPropertyList(forType: .fileURL) as? String,
                       "file:///tmp/report.pdf")
        XCTAssertEqual(
            writer.pasteboardPropertyList(forType: PasteboardTypes.legacyFilenames) as? [String],
            ["/tmp/report.pdf"]
        )
    }

    func testFolderItem_writerAdvertisesDirectFileRepresentations() throws {
        let item = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
    }

    func testImageItem_writerAdvertisesDirectFileRepresentationsAndTIFF() throws {
        let item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertTrue(advertised.contains(UTType.tiff.identifier),
                      "Image items should advertise the TIFF bitmap fallback.")
    }

    func testTextItem_advertisesPlainText() throws {
        let item = ShelfItem(kind: .text, displayName: "note", text: "hello shelf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        // An NSPasteboardItem can be written to only one pasteboard (a second
        // write throws), so write once and assert types and data on that board.
        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier),
                      "Expected public.utf8-plain-text in \(advertised).")
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello shelf")
    }

    func testURLItem_advertisesURLAndText_butNotFileURL() throws {
        let item = ShelfItem(kind: .url, displayName: "Apple", urlString: "https://www.apple.com")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.url.identifier))
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier))
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "A web URL must exclude public.file-url.")
        // Read back the way a destination does (NSURL, then the text fallback).
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.url), "https://www.apple.com")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://www.apple.com")
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls, [URL(string: "https://www.apple.com")!])
    }

    func testCutItem_writerAdvertisesPromiseOnly_noFileURL() throws {
        var item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let provider = try XCTUnwrap(writer as? FilePromiseProvider,
                                     "Managed moves require a promise provider that can confirm the destination write.")
        XCTAssertEqual(provider.fileType, DragPayloadBuilder.promisedFileType(for: item))
        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "public.file-url bypasses delivery confirmation for a managed move: \(advertised)")
        XCTAssertFalse(advertised.contains(PasteboardTypes.legacyFilenames.rawValue),
                       "Managed moves must require delivery confirmation through every representation.")
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        XCTAssertTrue(advertised.contains { promiseTypes.contains($0) },
                      "Managed moves must require a promise write at every destination: \(advertised)")
        // No file URL data either: not advertised, and a request returns nil.
        XCTAssertNil(writer.pasteboardPropertyList(forType: .fileURL))
    }

    func testCutImageItem_noTiffFallbackEither() throws {
        var item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertFalse(advertised.contains(UTType.tiff.identifier),
                       "TIFF consumers cannot confirm delivery of a managed image.")
        XCTAssertTrue(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
    }

    func testTutorialFileWriterCarriesPrivateTokenAlongsideRealFileRepresentations() throws {
        let item = ShelfItem(kind: .file,
                             path: "/tmp/OpenYoink 练习文件.txt",
                             displayName: "OpenYoink 练习文件.txt")
        let token = UUID().uuidString
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(
            for: item,
            bookmarkService: bookmarkService,
            tutorialSessionToken: token
        ))

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(PasteboardTypes.fileURL.rawValue))
        XCTAssertTrue(advertised.contains(PasteboardTypes.legacyFilenames.rawValue))
        XCTAssertTrue(advertised.contains(PasteboardTypes.tutorialSession.rawValue))
        XCTAssertFalse(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertNotNil(writer as? DirectFilePasteboardWriter)
        XCTAssertEqual(writer.pasteboardPropertyList(forType: PasteboardTypes.tutorialSession) as? String,
                       token)
    }

    /// Delivery confirmation: once a cut item's promise is written, the sink
/// reports the item ID.
    func testCutItem_deliverySink_reportsItemID() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managedSource = directory.appendingPathComponent("cut.txt")
        try "cut content".write(to: managedSource, atomically: true, encoding: .utf8)
        var item = ShelfItem(kind: .file, path: managedSource.path, displayName: "cut.txt")
        item.isCut = true

        let deliveredID = Mutex<UUID?>(nil)
        let deliveredURL = Mutex<URL?>(nil)
        let sink = DeliverySink(
            promiseRequested: { _ in },
            delivered: { id, url in
                deliveredID.withLock { $0 = id }
                deliveredURL.withLock { $0 = url }
            },
            failed: { _ in XCTFail("the write should succeed") }
        )
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(
            for: item, bookmarkService: bookmarkService, delivery: sink))
        let provider = try XCTUnwrap(writer as? FilePromiseProvider)
        let destination = directory.appendingPathComponent("delivered/cut.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(deliveredID.withLock { $0 }, item.id)
        XCTAssertEqual(deliveredURL.withLock { $0 }, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "cut content")
    }

    func testInvalidItems_returnNilWriter() {
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "empty"), // no text
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "no url"), // no urlString
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "bad", urlString: "ht tp://bad url"), // invalid URL
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .file, displayName: "ghost"), // no path
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: makeItem(kind: .stack), // unexpanded stack
            bookmarkService: bookmarkService))
    }

    func testMakeDraggingItems_multiSelection_producesOnePerItem() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "b", text: "b"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ]
        let frame = NSRect(x: 0, y: 0, width: 88, height: 100)

        let draggingItems = DragPayloadBuilder.makeDraggingItems(for: items, frame: frame, bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3)
        for draggingItem in draggingItems {
            XCTAssertEqual(draggingItem.draggingFrame, frame)
        }
    }

    func testMakeDraggingItems_stackExpandsToChildren() {
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [
            ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png"),
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ])

        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: [stack], frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3, "dragging a stack drags all its children")
    }

    func testMakeDraggingItems_skipsUnbuildableItems() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "empty"), // no text → nil writer
        ]
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: items, frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)
        XCTAssertEqual(draggingItems.count, 1)
    }
}
