import AppKit
import UniformTypeIdentifiers

enum PasteboardTypes {
    // MARK: - Type constants

    /// Finder's and most apps' file representation.
    static let fileURL: NSPasteboard.PasteboardType = .fileURL
    /// Chromium's macOS file-upload drop path still reads the legacy
    /// filename-list flavor even when `public.file-url` is present. AppKit no
    /// longer exposes the deprecated constant to Swift, so keep the wire
    /// value local and advertise it only alongside a real direct file URL.
    static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    /// `public.utf8-plain-text`
    static let plainText: NSPasteboard.PasteboardType = .string
    /// `public.html`
    static let html = NSPasteboard.PasteboardType(UTType.html.identifier)
    /// `public.rtf`
    static let rtf = NSPasteboard.PasteboardType(UTType.rtf.identifier)
    /// `public.png`
    static let png = NSPasteboard.PasteboardType(UTType.png.identifier)
    /// `public.tiff`
    static let tiff = NSPasteboard.PasteboardType(UTType.tiff.identifier)
    /// Generic image data.
    static let image = NSPasteboard.PasteboardType(UTType.image.identifier)
    /// `public.url`
    static let url = NSPasteboard.PasteboardType(UTType.url.identifier)
    /// The text supertype; conformance covers utf16 and other text flavors.
    static let text = NSPasteboard.PasteboardType(UTType.text.identifier)
    /// A MIME flavor, not a UTI (`UTType("text/uri-list")` is nil); bridged to
    /// a dyn.* type. Browsers use it for multi-link drags.
    static let uriList = NSPasteboard.PasteboardType("text/uri-list")
    /// Contact cards (.vcf).
    static let vCard = NSPasteboard.PasteboardType(UTType.vCard.identifier)
    /// Declared with *no* supertypes, so the generic registrations
    /// (public.data, …) miss it; registered explicitly.
    static let calendarEvent = NSPasteboard.PasteboardType(UTType.calendarEvent.identifier)
    /// Conforms only to `public.message`, outside data/item; registered
    /// explicitly (Mail drags use it or a promise).
    static let emailMessage = NSPasteboard.PasteboardType(UTType.emailMessage.identifier)
    /// Generic fallback. `availableType(from:)` follows UTI conformance (a
    /// pasteboard declaring public.png matches public.data and public.image,
    /// and can even convert to public.tiff); non-UTI legacy flavors
    /// (text/uri-list, NSFilenamesPboardType) are bridged to dyn.* and match it
    /// too. Undeclared reverse-DNS identifiers don't.
    static let data = NSPasteboard.PasteboardType(UTType.data.identifier)

    static let item = NSPasteboard.PasteboardType(UTType.item.identifier)
    /// `public.content`
    static let content = NSPasteboard.PasteboardType(UTType.content.identifier)
    /// The UTI form of NSFileContentsPboardType; the SDK has no `UTType`
    /// constant for it.
    static let fileContents = NSPasteboard.PasteboardType("public.file-contents")

    static let tutorialSession = NSPasteboard.PasteboardType("com.weijue.OpenYoink.tutorial-session")

    /// The promise types `NSFilePromiseReceiver` reads (Apple recommends
    /// registering its `readableDraggedTypes` rather than UTI strings).
    static let filePromiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static let imageTypes: [NSPasteboard.PasteboardType] =
        [png, tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), image]
    /// Text. The main chain takes plain text; HTML/RTF without plain text
    /// becomes an .html/.rtf file in the fallback chain.
    static let textTypes: [NSPasteboard.PasteboardType] = [plainText, html, rtf]

    static let genericFallbackTypes: [NSPasteboard.PasteboardType] = [data, item, content, fileContents]

    static let dragInTypes: [NSPasteboard.PasteboardType] =
        filePromiseTypes + [fileURL] + imageTypes + [url] + textTypes
        + [text, uriList, vCard, calendarEvent, emailMessage]
        + genericFallbackTypes

    // MARK: - Capability probing (pure functions)

    /// Dispatch categories; `allCases` order is the priority.
    enum Category: CaseIterable, Equatable, Sendable {
        /// File promises (sources that create the file on drop: Photos, large
/// Safari images).
        case filePromise
        /// File or folder URLs that already exist on disk.
        case fileURL
        /// Bitmap data without a file URL (PNG, TIFF, generic image).
        case image
        /// Web URL
        case url
        /// Plain text, HTML, RTF.
        case text
    }

    /// The categories the types cover, by priority.
    static func availableCategories(in types: [NSPasteboard.PasteboardType]) -> [Category] {
        Category.allCases.filter { supports($0, types: types) }
    }

    /// The top category, or nil when nothing is handled (refuse the drop).
    static func preferredCategory(in types: [NSPasteboard.PasteboardType]) -> Category? {
        availableCategories(in: types).first
    }

    static func supports(_ category: Category, types: [NSPasteboard.PasteboardType]) -> Bool {
        switch category {
        case .filePromise:
            types.contains { filePromiseTypes.contains($0) }
        case .fileURL:
            types.contains(fileURL)
        case .image:
            types.contains { imageTypes.contains($0) }
        case .url:
            types.contains(url)
        case .text:
            types.contains { textTypes.contains($0) }
        }
    }

    static func hasFileDragContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        supports(.fileURL, types: types) || supports(.filePromise, types: types)
    }

    /// Preferred image types: PNG is written as is, TIFF and generic images are
/// converted to PNG.
    static func preferredImageType(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        imageTypes.first { types.contains($0) }
    }

    /// Highlight/accept decision. With the broad registrations, nearly any drag
    /// that reaches `draggingEntered` materializes into something, so any
    /// declared type is accepted; only a drag declaring nothing is refused.
    /// Refusing our own cards is the caller's `draggingSource` check.
    static func hasImportableContent(in types: [NSPasteboard.PasteboardType]) -> Bool {
        !types.isEmpty
    }

    /// Types the main chain or a dedicated branch handles, excluded from generic
    /// materialization (HTML/RTF, plain text, URL, file URL, uri-list).
    static let handledElsewhereTypes: [NSPasteboard.PasteboardType] =
        [fileURL, url, uriList] + textTypes + filePromiseTypes

    /// Extensions for known types without `preferredFilenameExtension`
    /// (calendar-event, email-message), which targets like Calendar and Mail
    /// need to recognize the file.
    static let wellKnownExtensionFallback: [NSPasteboard.PasteboardType: String] = [
        calendarEvent: "ics",
        emailMessage: "eml",
    ]

    /// A candidate type and its tier (1 most specific, 3 most generic).
    struct MaterializationCandidate: Equatable, Sendable {
        let type: NSPasteboard.PasteboardType
        /// 1 = declared, non-dynamic, with an extension; 2 = declared, non-dynamic,
        /// without; 3 = dynamic, bridged, legacy or generic.
        let tier: Int
    }

    static func materializationCandidates(in types: [NSPasteboard.PasteboardType]) -> [MaterializationCandidate] {
        let excluded = Set(handledElsewhereTypes)
        var tier1: [MaterializationCandidate] = []
        var tier2: [MaterializationCandidate] = []
        var tier3: [MaterializationCandidate] = []
        for type in types where !excluded.contains(type) {
            guard let utType = UTType(type.rawValue), !utType.isDynamic else {
                tier3.append(MaterializationCandidate(type: type, tier: 3)) // not a UTI, or a bridged dyn.* flavor
                continue
            }
            if utType.preferredFilenameExtension != nil {
                tier1.append(MaterializationCandidate(type: type, tier: 1))
            } else if genericFallbackTypes.contains(type) {
                tier3.append(MaterializationCandidate(type: type, tier: 3))
            } else if utType.conforms(to: .text) || utType.conforms(to: .url) {
                continue // text or URL without an extension: the string branch fits better
            } else {
                tier2.append(MaterializationCandidate(type: type, tier: 2))
            }
        }
        return tier1 + tier2 + tier3
    }

    /// `preferredFilenameExtension`, then the known table, then "dat".
    static func materializationFileExtension(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let ext = utType.preferredFilenameExtension, !ext.isEmpty {
            return ext
        }
        return wellKnownExtensionFallback[type] ?? "dat"
    }

    /// The type's localized description (vCard → "electronic business card"),
    /// else a localized "Dropped Item"; without extension.
    static func materializedDisplayBaseName(for type: NSPasteboard.PasteboardType) -> String {
        if let utType = UTType(type.rawValue), !utType.isDynamic,
           let description = utType.localizedDescription, !description.isEmpty {
            return description
        }
        return String(localized: "Dropped Item")
    }
}
