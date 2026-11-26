import AppKit
import OSLog

/// Delivers a managed copy through a file promise. Finder must invoke the
/// write delegate before the app can confirm delivery and remove the copy.
final class FilePromiseProvider: NSFilePromiseProvider {
    /// Everything one promise write needs.
    struct Payload: Equatable, Sendable {
        /// The source as resolved when the drag began.
        let sourceURL: URL
        /// Re-resolved at write time for sandbox access, since the file may
        /// have moved while on the shelf; falls back to `sourceURL`.
        let bookmark: Data?
        /// Offered to the target as the file name.
        let suggestedName: String

        let promisedFileType: String
    }

    /// `NSFilePromiseProvider.delegate` is weak.
    private let promiseDelegate: FilePromiseDelegate

    init(payload: Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)? = nil) {
        let delegate = FilePromiseDelegate(payload: payload,
                                           bookmarkService: bookmarkService,
                                           onPromiseRequested: onPromiseRequested,
                                           onDelivered: onDelivered,
                                           onError: onError)
        self.promiseDelegate = delegate

        super.init()
        fileType = payload.promisedFileType
        self.delegate = delegate
    }

    nonisolated static func writeCopy(of payload: Payload,
                                      to destinationURL: URL,
                                      bookmarkService: BookmarkService) throws {
        var sourceURL = payload.sourceURL
        if let bookmark = payload.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            sourceURL = resolved.url
        }
        try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
    }
}

nonisolated final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let payload: FilePromiseProvider.Payload
    private let bookmarkService: BookmarkService
    /// Called when the destination selects the promised-file representation.
    private let onPromiseRequested: (@Sendable () -> Void)?

    private let onDelivered: (@Sendable (URL) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?
    private let writeQueue: OperationQueue
    private let logger = Log.make(category: "FilePromiseProvider")

    init(payload: FilePromiseProvider.Payload,
         bookmarkService: BookmarkService,
         onPromiseRequested: (@Sendable () -> Void)? = nil,
         onDelivered: (@Sendable (URL) -> Void)? = nil,
         onError: (@Sendable (Error) -> Void)?) {
        self.payload = payload
        self.bookmarkService = bookmarkService
        self.onPromiseRequested = onPromiseRequested
        self.onDelivered = onDelivered
        self.onError = onError
        let queue = OperationQueue()
        queue.name = "com.weijue.OpenYoink.FilePromiseWrite"
        queue.qualityOfService = .userInitiated
        self.writeQueue = queue
        super.init()
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return payload.suggestedName
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        writeQueue
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        // This is the first reliable fact that the destination selected the
        // promise representation. `fileNameForType` may be queried while the
        // pasteboard is merely being prepared.
        onPromiseRequested?()
        do {
            try FilePromiseProvider.writeCopy(of: payload, to: url, bookmarkService: bookmarkService)
            onDelivered?(url)
            completionHandler(nil)
        } catch {
            logger.error("File promise write failed for \(self.payload.suggestedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(error)
            completionHandler(error)
        }
    }
}
