import AppKit
import UniformTypeIdentifiers

struct DeliverySink: Sendable {
    /// The destination selected the promised-file representation.
    var promiseRequested: @Sendable (UUID) -> Void
    /// Written: the item ID and the destination URL.
    var delivered: @Sendable (UUID, URL) -> Void
    /// Failed: the item ID (the item stays on the shelf and can be retried).
    var failed: @Sendable (UUID) -> Void
}

enum DragPayloadBuilder {
    /// How each kind is represented.
    enum Strategy: Equatable, Sendable {
        /// Files and folders: direct file representation; managed cut items: a file promise.
        case fileBacked
        /// Images: file-backed plus a `public.tiff` bitmap fallback.
        case fileBackedImage
        /// `public.utf8-plain-text`. Only plain text is stored (drops don't keep
        /// HTML/RTF originals), so there is no rich representation to offer.
        case plainText
        /// Web URL`public.url` + plain text
        case webURL
    }

    /// A stack isn't dragged as a whole (`flattenedItems` expands it), so nil.
    static func strategy(for item: ShelfItem) -> Strategy? {
        switch item.kind {
        case .file, .folder: .fileBacked
        case .image: .fileBackedImage
        case .text: .plainText
        case .url: .webURL
        case .stack: nil
        }
    }

    /// Mirrors the guards used by writer construction without creating AppKit
    /// objects. Delivery batches use it so skipped malformed cards do not
    /// inflate the expected outcome count and leave the activity strip stuck.
    static func canMakePasteboardWriter(for item: ShelfItem) -> Bool {
        switch strategy(for: item) {
        case .fileBacked, .fileBackedImage:
            return item.path != nil
        case .plainText:
            return item.text?.isEmpty == false
        case .webURL:
            guard let value = item.urlString else { return false }
            return URL(string: value) != nil
        case nil:
            return false
        }
    }

    /// The promised content UTI: a folder → `public.folder`; otherwise inferred
    /// from the extension; no or unknown extension → `public.data`.
    ///
    /// `NSFilePromiseProvider.init(fileType:)` raises an NSException (uncatchable
    /// in Swift) for a type conforming to neither data nor directory, and on
    /// macOS 26 some canonical UTIs are no longer declared
    /// (`UTType("public.pdf") == nil`). So only types from
    /// `UTType(filenameExtension:)` verified to conform to .data/.directory are
    /// used; identifiers of static members such as `UTType.pdf` are not.
    static func promisedFileType(for item: ShelfItem) -> String {
        if item.kind == .folder {
            return UTType.folder.identifier
        }
        if let path = item.path {
            let pathExtension = URL(fileURLWithPath: path).pathExtension
            if !pathExtension.isEmpty,
               let type = UTType(filenameExtension: pathExtension),
               type.conforms(to: .data) || type.conforms(to: .directory) {
                return type.identifier
            }
        }
        return UTType.data.identifier
    }

    // MARK: - Writer construction

    /// AppKit transfers file access when the destination reads the pasteboard,
    /// which can happen well after the writers have been constructed.
    static func makeFileAccessLease(for items: [ShelfItem],
                                    bookmarkService: BookmarkService) -> BookmarkAccessLease {
        var accessedURLs: [URL] = []
        for item in items.flattened where !item.isCut {
            guard strategy(for: item) == .fileBacked || strategy(for: item) == .fileBackedImage,
                  let bookmark = item.bookmark,
                  let resolved = try? bookmarkService.resolve(bookmark) else { continue }
            if bookmarkService.startAccessing(resolved.url) {
                accessedURLs.append(resolved.url)
            }
        }
        return BookmarkAccessLease(accessedURLs: accessedURLs, service: bookmarkService)
    }

    @MainActor
    static func makePasteboardWriter(for item: ShelfItem,
                                     bookmarkService: BookmarkService,
                                     delivery: DeliverySink? = nil,
                                     tutorialSessionToken: String? = nil) -> NSPasteboardWriting? {
        switch strategy(for: item) {
        case .fileBacked, .fileBackedImage:
            return makeFileBackedWriter(for: item,
                                        bookmarkService: bookmarkService,
                                        delivery: delivery,
                                        tutorialSessionToken: tutorialSessionToken)
        case .plainText:
            return makeTextItem(for: item)
        case .webURL:
            return makeURLItem(for: item)
        case nil:
            return nil
        }
    }

    /// One `NSDraggingItem` per draggable item. `frame` is the dragged card in
    /// the source view's coordinates (shared by all items; the system fans them
    /// out); images come from `dragImage`.
    @MainActor
    static func makeDraggingItems(for items: [ShelfItem],
                                  frame: NSRect,
                                  bookmarkService: BookmarkService,
                                  delivery: DeliverySink? = nil,
                                  tutorialTokensByItemID: [UUID: String] = [:],
                                  cardPreviewImage: NSImage? = nil) -> [NSDraggingItem] {
        let flattened = items.flattened
        let singleItemPreview = flattened.count == 1 ? cardPreviewImage : nil
        return flattened.compactMap { item in
            guard let writer = makePasteboardWriter(
                for: item,
                bookmarkService: bookmarkService,
                delivery: delivery,
                tutorialSessionToken: tutorialTokensByItemID[item.id]
            ) else {
                return nil
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let contents = singleItemPreview ?? dragImage(for: item)
            // The preview keeps the item's own aspect ratio, so the frame
            // follows it instead of squeezing it back into the card's box. It
            // is centred on the card: Shelf reordering targets the card centre,
            // and the preview the user steers must sit on that same point.
            let draggingFrame = singleItemPreview.map {
                NSRect(x: frame.midX - $0.size.width / 2,
                       y: frame.midY - $0.size.height / 2,
                       width: $0.size.width,
                       height: $0.size.height)
            } ?? frame
            draggingItem.setDraggingFrame(draggingFrame, contents: contents)
            return draggingItem
        }
    }

    /// Prefers the card's loaded thumbnail (`DragImageCache`; drag start is
    /// synchronous, so only the cache will do), else `NSWorkspace.icon(forFile:)`
    /// (synchronous, needs no file access); text and URLs use the card's
    /// placeholder symbol. Always 64 pt.
    @MainActor
    static func dragImage(for item: ShelfItem) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        if let cached = DragImageCache.image(for: item.id) {
            return NSImage(cgImage: cached, size: size)
        }
        if let path = item.path {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = size
            return icon
        }
        let symbolName = switch item.kind {
        case .text: "doc.text"
        case .url: "link"
        default: "doc"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        image.size = size
        return image
    }

    // MARK: - File/folder/image

    @MainActor
    private static func makeFileBackedWriter(for item: ShelfItem,
                                             bookmarkService: BookmarkService,
                                             delivery: DeliverySink?,
                                             tutorialSessionToken: String?) -> NSPasteboardWriting? {
        guard let path = item.path else { return nil }

        let sourceURL: URL
        if let bookmark = item.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            sourceURL = resolved.url
        } else {
            sourceURL = URL(fileURLWithPath: path)
        }
        let bookmark = item.bookmark
        let includeImageFallback = strategy(for: item) == .fileBackedImage && !item.isCut
        let tiffDataProvider: (@Sendable () -> Data?)?
        if includeImageFallback {
            // Lazy: the file is read only when a destination asks for public.tiff.
            tiffDataProvider = { tiffData(sourceURL: sourceURL, bookmark: bookmark, bookmarkService: bookmarkService) }
        } else {
            tiffDataProvider = nil
        }
        if !item.isCut {
            return DirectFilePasteboardWriter(
                fileURL: sourceURL,
                tiffDataProvider: tiffDataProvider,
                tutorialSessionToken: tutorialSessionToken
            )
        }
        let itemID = item.id
        // Explicitly typed locals: a ternary of closure literals defeats type
// inference diagnostics.
        let onPromiseRequested: @Sendable () -> Void = {
            delivery?.promiseRequested(itemID)
        }
        let onDelivered: @Sendable (URL) -> Void = { url in
            delivery?.delivered(itemID, url)
        }
        let onError: @Sendable (Error) -> Void = { _ in
            delivery?.failed(itemID)
        }
        return FilePromiseProvider(
            payload: FilePromiseProvider.Payload(
                sourceURL: sourceURL,
                bookmark: bookmark,
                suggestedName: item.displayName,
                promisedFileType: promisedFileType(for: item)
            ),
            bookmarkService: bookmarkService,
            onPromiseRequested: onPromiseRequested,
            onDelivered: onDelivered,
            onError: onError
        )
    }

    /// Reads the image within security scope and exports TIFF. `NSImage` isn't
    /// Sendable; it is created and reduced to `Data` in place.
    nonisolated static func tiffData(sourceURL: URL, bookmark: Data?, bookmarkService: BookmarkService) -> Data? {
        var url = sourceURL
        if let bookmark, let resolved = try? bookmarkService.resolve(bookmark) {
            url = resolved.url
        }
        return bookmarkService.withSecurityScopedAccess(to: url) {
            NSImage(contentsOf: url)?.tiffRepresentation
        }
    }

    // MARK: - Text

    /// `public.utf8-plain-text`, written directly on an `NSPasteboardItem`.
    @MainActor
    private static func makeTextItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let text = item.text, !text.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(text, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }

    // MARK: - URL

    /// `public.url` plus a plain-text fallback (text fields, address bars). No
    /// `public.file-url`: that would misrepresent an http(s) URL and could
    /// mislead Finder-like destinations.
    @MainActor
    private static func makeURLItem(for item: ShelfItem) -> NSPasteboardItem? {
        guard let urlString = item.urlString, URL(string: urlString) != nil else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(urlString, forType: PasteboardTypes.url)
        pasteboardItem.setString(urlString, forType: PasteboardTypes.plainText)
        return pasteboardItem
    }
}
