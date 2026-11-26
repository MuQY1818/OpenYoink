import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

final class PasteboardConformanceProbeTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkProbeTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    func testProbe_declaredPNG_matchesDataImageAndConvertibleTIFF() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.image")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        // Convertible flavors: declaring png also offers tiff.
        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        // Unrelated families don't match.
        XCTAssertNil(pasteboard.availableType(from: [.string]))
    }

    func testProbe_declaredPlainText_matchesTextSupertypes() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.text")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.plain-text")]))
    }

    /// Only one way: a declared supertype doesn't match a subtype query.
    func testProbe_expansionIsDirectional_urlDoesNotMatchFileURL() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("public.url")], owner: nil)
        pasteboard.setString("https://example.com", forType: T("public.url"))

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
    }

    func testProbe_uriListFlavor_bridgesToDynamicTypeMatchingData_andReadsAtPasteboardLevel() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://example.com/", forType: PasteboardTypes.uriList)

        // The raw flavor string stays in the pasteboard's types.
        XCTAssertTrue(pasteboard.types?.contains(PasteboardTypes.uriList) ?? false)
        // The bridged dyn.* type matches public.data, so generic registration catches it.
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        // Reading the raw flavor works at the pasteboard level (not at the item level, below).
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.uriList), "https://example.com/")
        // The item has only the bridged dyn.* type: the raw flavor reads nothing.
        let item = pasteboard.pasteboardItems?.first
        XCTAssertEqual(item?.string(forType: PasteboardTypes.uriList), nil)
    }

    func testProbe_undeclaredReverseDNSIdentifier_matchesNothingGeneric() {
        let custom = T("com.openyoink.probe.undeclared-\(UUID().uuidString)")
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([custom], owner: nil)
        pasteboard.setData(Data([1, 2, 3]), forType: custom)

        XCTAssertNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.content")]))
    }

    func testProbe_calendarEventAndEmailMessage_haveNoDataConformance() {

        XCTAssertFalse(UTType.calendarEvent.conforms(to: .data))
        XCTAssertFalse(UTType.calendarEvent.conforms(to: .item))
        XCTAssertFalse(UTType.emailMessage.conforms(to: .data))
    }

    func testProbe_materializationExtensionFacts() {
        XCTAssertEqual(UTType.vCard.preferredFilenameExtension, "vcf")
        // No extension tag: why `wellKnownExtensionFallback` exists.
        XCTAssertNil(UTType.calendarEvent.preferredFilenameExtension)
        XCTAssertNil(UTType.emailMessage.preferredFilenameExtension)
        XCTAssertNotNil(UTType.vCard.localizedDescription)
    }

    /// `UTType(_:)` returns nil for non-UTI strings and undeclared identifiers,
    /// so it can't decide conformance for arbitrary pasteboard type strings.
    func testProbe_uttypeInit_nilForNonUTIAndUndeclaredIdentifiers() {
        XCTAssertNil(UTType("text/uri-list"))
        XCTAssertNil(UTType("com.openyoink.probe.undeclared-\(UUID().uuidString)"))
        XCTAssertNil(UTType("NSFilenamesPboardType"))
        // For contrast: a declared type resolves and its conformance can be queried.
        XCTAssertTrue(UTType("com.adobe.pdf")?.conforms(to: .data) ?? false)
    }

    func testProbe_htmlOnlyItem_hasNoPlainTextButReadableHTMLData() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data("<b>hi</b>".utf8), forType: PasteboardTypes.html)

        let item = pasteboard.pasteboardItems?.first
        XCTAssertNil(item?.string(forType: .string)) // the main chain's text stage reads nothing → why branch b exists
        XCTAssertNotNil(item?.data(forType: PasteboardTypes.html))
    }
}
