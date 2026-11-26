import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

@MainActor
final class DropImportCoordinatorTests: XCTestCase {

    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        let coordinator: DropImportCoordinator
        var temporaryURLs: [URL] = []

        init() {
            let materializedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-Materialized-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: materializedDir)
            coordinator = DropImportCoordinator(bookmarkService: bookmarkService, tempFileService: tempFileService)
            temporaryURLs.append(materializedDir)
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

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
    }

    private func makeTempFile(in context: inout Context, named name: String = "sample.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-\(name)")
        try "sample content".write(to: url, atomically: true, encoding: .utf8)
        context.temporaryURLs.append(url)
        return url
    }

    private func makeTempDirectory(in context: inout Context) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        context.temporaryURLs.append(url)
        return url
    }

    /// 1×1 PNG
    private func makePNGData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Async callbacks this test doesn't use.
    private func ignoringAsyncItems() -> @MainActor (ShelfItem) -> Void {
        { _ in XCTFail("no async materialization expected for this pasteboard") }
    }

    // MARK: - fileURL

    func testImport_fileURL_producesFileItemWithBookmark() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "notes.txt")
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.path, fileURL.path)
        XCTAssertEqual(item.displayName, fileURL.lastPathComponent)
        XCTAssertNotNil(item.bookmark)
        XCTAssertNil(item.sourceApp) // cross-app drags have no source app
    }

    func testImport_directoryURL_producesFolderItem_notExpanded() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folderURL = try makeTempDirectory(in: &context)
        // A folder with a file in it: folders aren't expanded.
        try "inner".write(to: folderURL.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([folderURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertNil(item.children)
    }

    func testImport_imageFileURL_producesImageKind() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)-pic.png")
        try makePNGData().write(to: imageURL)
        context.temporaryURLs.append(imageURL)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([imageURL as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(try XCTUnwrap(result.items.only).kind, .image)
    }

    func testImport_multipleFileURLs_preservesOrder() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let first = try makeTempFile(in: &context, named: "a.txt")
        let second = try makeTempFile(in: &context, named: "b.txt")
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.items.map(\.displayName), [first.lastPathComponent, second.lastPathComponent])
    }

    func testTutorialTokenAllowsOnlyCurrentInternalSessionAndReportsRealImportedItem() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "OpenYoink 练习文件.txt")
        let token = UUID().uuidString
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.addTypes([PasteboardTypes.tutorialSession], owner: nil)
        pasteboard.setString(token, forType: PasteboardTypes.tutorialSession)
        context.coordinator.isActiveTutorialToken = { $0 == token }

        XCTAssertTrue(context.coordinator.acceptsInternalTutorialDrag(pasteboard))
        var callback: (String, [ShelfItem])?
        context.coordinator.onTutorialItemsImported = { callback = ($0, $1) }
        let result = context.coordinator.importItems(from: pasteboard,
                                                     onAsyncItemReady: ignoringAsyncItems())
        context.coordinator.noteSynchronousTutorialImport(from: pasteboard,
                                                          items: result.items)

        XCTAssertEqual(callback?.0, token)
        XCTAssertEqual(callback?.1.only?.path, fileURL.path)

        context.coordinator.isActiveTutorialToken = { _ in false }
        XCTAssertFalse(context.coordinator.acceptsInternalTutorialDrag(pasteboard))
    }

    // MARK: - File promise kind inference

    func testInferFileKind_actualExtensionWinsOverReceiverTypeCollection() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let textURL = try makeTempFile(in: &context, named: "mixed-promise.txt")

        let kind = DropImportCoordinator.inferFileKind(
            for: textURL,
            promisedTypeIdentifiers: [UTType.png.identifier, UTType.plainText.identifier]
        )

        XCTAssertEqual(kind, .file)
    }

    func testInferFileKind_singlePromisedImageType_isFallbackForExtensionlessFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "extensionless")

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: fileURL,
                promisedTypeIdentifiers: [UTType.png.identifier]
            ),
            .image
        )
    }

    func testInferFileKind_mixedPromisedTypes_doNotMisclassifyExtensionlessFile() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context, named: "extensionless")

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: fileURL,
                promisedTypeIdentifiers: [UTType.png.identifier, UTType.plainText.identifier]
            ),
            .file
        )
    }

    func testInferFileKind_actualDirectoryWinsOverPromisedImageType() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let folderURL = try makeTempDirectory(in: &context)

        XCTAssertEqual(
            DropImportCoordinator.inferFileKind(
                for: folderURL,
                promisedTypeIdentifiers: [UTType.png.identifier]
            ),
            .folder
        )
    }

    // MARK: - Priority

    /// With a file URL and text, the file URL wins and the text is ignored.
    func testImport_fileURLAndText_fileURLWins() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let fileURL = try makeTempFile(in: &context)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([fileURL as NSURL, "dragged text" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertNil(item.text)
    }

    // MARK: - Image data

    func testImport_pngData_materializesImageItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pngData = try makePNGData()
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(pngData, forType: .png)

        let itemReady = expectation(description: "image item materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, DropImportCoordinator.materializedImageDisplayName)
        XCTAssertNotNil(item.bookmark)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path))
        // The written file equals the original PNG.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), pngData)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.itemIDs, [item.id])
    }

    func testClipboardImageImportDoesNotFallBackToFileURLOrText() throws {
        var context = makeContext()
        defer { context.cleanup() }
        let file = try makeTempFile(in: &context)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let text = NSPasteboardItem()
        text.setString("copied text", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL, text]))
        context.coordinator.onImportHandled = { XCTFail("nothing should be imported") }

        let count = context.coordinator.importClipboardImages(
            from: pasteboard, onItemReady: ignoringAsyncItems()
        )

        XCTAssertEqual(count, 0)
        XCTAssertNil(context.coordinator.transferStore.currentTask)
    }

    func testClipboardImageImportUsesImageEvenWhenOtherTypesArePresent() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pngData = try makePNGData()
        let mixed = NSPasteboardItem()
        mixed.setString("https://example.com/image", forType: .URL)
        mixed.setData(pngData, forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([mixed]))

        let itemReady = expectation(description: "clipboard image materialized")
        var received: ShelfItem?
        let count = context.coordinator.importClipboardImages(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }
        XCTAssertEqual(count, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.displayName, String(localized: "Clipboard Image.png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(item.path))), pngData)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
    }

    // MARK: - URL

    func testImport_publicURL_producesURLItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.url], owner: nil)
        pasteboard.setString("https://www.apple.com", forType: PasteboardTypes.url)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .url)
        XCTAssertEqual(item.urlString, "https://www.apple.com")
        XCTAssertEqual(item.displayName, "www.apple.com")
        XCTAssertNil(item.path)
        XCTAssertNil(item.bookmark)
    }

    // MARK: - Text

    func testImport_plainText_producesTextItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.writeObjects(["Hello shelf" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "Hello shelf")
        XCTAssertEqual(item.displayName, "Hello shelf")
    }

    func testImport_multilineText_displayNameUsesFirstLineTruncated() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let longLine = String(repeating: "x", count: 80)
        let pasteboard = makePasteboard()
        pasteboard.writeObjects(["\(longLine)\nsecond line" as NSString])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let displayName = try XCTUnwrap(result.items.only?.displayName)
        XCTAssertTrue(displayName.hasSuffix("…"))
        XCTAssertEqual(displayName.count, 61)
    }

    // MARK: - Unhandled

    func testImport_emptyPasteboard_isUnhandled() {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())
        XCTAssertFalse(result.handled)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
