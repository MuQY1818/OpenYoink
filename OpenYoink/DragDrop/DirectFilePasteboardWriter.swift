import AppKit

nonisolated final class DirectFilePasteboardWriter: NSObject, NSPasteboardWriting {
    private let fileURL: URL
    private let tiffDataProvider: (@Sendable () -> Data?)?
    private let tutorialSessionToken: String?

    init(fileURL: URL,
         tiffDataProvider: (@Sendable () -> Data?)? = nil,
         tutorialSessionToken: String? = nil) {
        self.fileURL = fileURL
        self.tiffDataProvider = tiffDataProvider
        self.tutorialSessionToken = tutorialSessionToken
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var result: [NSPasteboard.PasteboardType] = [
            PasteboardTypes.fileURL,
            PasteboardTypes.legacyFilenames,
        ]
        if tiffDataProvider != nil {
            result.append(PasteboardTypes.tiff)
        }
        if tutorialSessionToken != nil {
            result.append(PasteboardTypes.tutorialSession)
        }
        return result
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == PasteboardTypes.tiff ? .promised : []
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case PasteboardTypes.fileURL:
            fileURL.absoluteString as NSString
        case PasteboardTypes.legacyFilenames:
            [fileURL.path] as NSArray
        case PasteboardTypes.tiff where tiffDataProvider != nil:
            tiffDataProvider?()
        case PasteboardTypes.tutorialSession where tutorialSessionToken != nil:
            tutorialSessionToken as NSString?
        default:
            nil
        }
    }
}
