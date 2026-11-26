import AppKit
import XCTest
@testable import OpenYoink

@MainActor
final class DropImportFallbackTests: XCTestCase {
    /// Same fixtures pattern as DropImportCoordinatorTests: built in place,
/// cleaned up with defer.
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        let noticeCenter = ShelfNoticeModel()
        let coordinator: DropImportCoordinator
        var temporaryURLs: [URL] = []

        init() {
            let materializedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-Materialized-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: materializedDir)
            coordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                tempFileService: tempFileService,
                                                noticeCenter: noticeCenter)
            temporaryURLs.append(materializedDir)
        }

        func cleanup() {
            bookmarkService.stopAccessingAll()
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func makeContext() -> Context { Context() }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    private func ignoringAsyncItems() -> @MainActor (ShelfItem) -> Void {
        { _ in XCTFail("no async materialization expected for this pasteboard") }
    }

    func testFallback_htmlOnlyDrop_materializesHTMLFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let html = Data("<p>Hello <b>HTML</b></p><p>second</p>".utf8)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(html, forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, "Hello HTML.html")
        XCTAssertNotNil(item.bookmark)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "html")
        // The original is written unchanged, so dragging it to Pages or a browser
// keeps it rich.
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), html)
    }

    /// RTF only, with the system's plain-text bridge failing (valid RTF gets
    /// bridged utf8/utf16 flavors and becomes text in the main chain; this
    /// covers branch b when the bridge fails): becomes an .rtf file, with the
    /// localized fallback name when no text can be extracted.
    func testFallback_rtfWithoutPlainTextBridge_materializesRTFFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rtf = Data("not really rtf".utf8) // invalid RTF: the bridge fails when read
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.rtf], owner: nil)
        pasteboard.setData(rtf, forType: PasteboardTypes.rtf)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, String(localized: "Dropped RTF") + ".rtf")
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "rtf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), rtf)
    }

    /// HTML with no extractable text (only tags or images) gets the localized
/// fallback name.
    func testFallback_htmlWithoutExtractableText_usesLocalizedFallbackName() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data(#"<img src="x.png">"#.utf8), forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.displayName, String(localized: "Dropped HTML") + ".html")
    }

    func testFallback_uriList_producesURLItemPerLine() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://a.com/\r\n# a comment\r\n\r\nhttps://b.com/path",
                             forType: PasteboardTypes.uriList)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        XCTAssertEqual(result.items.map(\.urlString), ["https://a.com/", "https://b.com/path"])
        XCTAssertEqual(result.items.map(\.kind), [.url, .url])
        XCTAssertEqual(result.items.map(\.displayName), ["a.com", "b.com"])
    }

    /// vCard data: tier 1 (a concrete UTI with an extension) → a .vcf file.
    func testFallback_vCardData_materializesVCFFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcf = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test Person\r\nEND:VCARD\r\n".utf8)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(vcf, forType: T("public.vcard"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let itemReady = expectation(description: "vCard materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "vcf")
        XCTAssertTrue(item.displayName.hasSuffix(".vcf"))
        XCTAssertNotNil(item.bookmark)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), vcf)
    }

    func testFallback_unknownBinaryData_materializesDatFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let blob = Data([0x00, 0xFF, 0x01, 0xFE])
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.unknown-blob")], owner: nil)
        pasteboard.setData(blob, forType: T("com.openyoink.test.unknown-blob"))

        let itemReady = expectation(description: "blob materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "dat")
        XCTAssertEqual(item.displayName, String(localized: "Dropped Item") + ".dat")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), blob)
    }

    /// A vCard item and an unknown binary item each go through branch c on their own.
    func testFallback_mixedFallbackItems_eachMaterializesIndependently() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcfItem = NSPasteboardItem()
        vcfItem.setData(Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\nEND:VCARD\r\n".utf8),
                        forType: T("public.vcard"))
        let blobItem = NSPasteboardItem()
        blobItem.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: T("com.openyoink.test.unknown-blob"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([vcfItem, blobItem])

        let allReady = expectation(description: "both materialized")
        allReady.expectedFulfillmentCount = 2
        var extensions: [String] = []
        let result = context.coordinator.importItems(from: pasteboard) { item in
            if let path = item.path {
                extensions.append(URL(fileURLWithPath: path).pathExtension)
            }
            allReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 2)
        await fulfillment(of: [allReady], timeout: 5)
        XCTAssertEqual(Set(extensions), ["vcf", "dat"])
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.phase, .delivered)
        XCTAssertEqual(context.coordinator.transferStore.currentTask?.itemIDs.count, 2)
    }

    func testFallback_exoticStringType_producesTextItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("exotic payload", forType: T("public.utf8-external-plain-text"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "exotic payload")
        XCTAssertEqual(item.displayName, "exotic payload")
    }

    /// Types declared but nothing readable: every item is logged, nothing comes
    /// out, so the drop is refused with a notice.
    func testFallback_itemWithNoReadableContent_isUnhandled_andShowsNotice() {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.void")], owner: nil)
        // No data written: an item without content.

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertFalse(result.handled)
        XCTAssertEqual(context.noticeCenter.message,
                       String(localized: "That content can't be added to the shelf yet."))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
