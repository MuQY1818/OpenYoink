import Foundation
import OSLog

final class CutMoveService: Sendable {
    /// Synchronously captured while the drag pasteboard grant is active.  The
    /// security-scoped bookmark in `referenceItem` lets the expensive copy run
    /// after `performDragOperation` returns.
    struct Request: Equatable, Sendable {
        let sourceURL: URL
        let displayName: String
        let referenceItem: ShelfItem
    }

    /// Why a move fell back to a reference.
    enum FallbackReason: Equatable, Sendable {
        /// The source is already inside the app container; silent, no notice.
        case sourceInsideContainer
        /// Copying into managed storage (or verifying the copy) failed; the original is untouched.
        case copyFailed
        /// The copy was in place but trashing the original failed (read-only
/// volume, …); the copy is removed, the original is untouched.
        case trashFailed
        /// The recovery transaction couldn't be written before the destructive
/// step; the copy is removed, the original is untouched.
        case transactionFailed
    }

    /// The result for one file.
    enum Outcome: Equatable, Sendable {
        /// Moved: `item.isCut` is true; path and bookmark point at the managed copy.
        case moved(ShelfItem)
        /// A plain reference item; `reason` lets the caller decide on a notice.
        case fallbackToReference(ShelfItem, FallbackReason)
    }

    let tempFileService: TempFileService
    let bookmarkService: BookmarkService
    let managedMoveJournal: ManagedMoveJournal
    /// The "inside the app container" root (the container's Data directory;
/// tests inject a temporary one).
    let containerURL: URL
    /// Trashes the original; tests inject a mock to check order and failures.
    let trashOriginal: @Sendable (URL) throws -> URL?

    private let logger = Log.make(category: "CutMove")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         managedMoveJournal: ManagedMoveJournal? = nil,
         containerURL: URL? = nil,
         trashOriginal: (@Sendable (URL) throws -> Void)? = nil) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.managedMoveJournal = managedMoveJournal ?? ManagedMoveJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent()
        )

        self.containerURL = containerURL
            ?? AppPaths.applicationSupport()  // <Data>/Library/Application Support/OpenYoink
                .deletingLastPathComponent()        // <Data>/Library/Application Support
                .deletingLastPathComponent()        // <Data>/Library
                .deletingLastPathComponent()        // <Data>
        if let trashOriginal {
            self.trashOriginal = { url in
                try trashOriginal(url)
                return nil
            }
        } else {
            self.trashOriginal = { url in
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return resultingURL as URL?
            }
        }
    }

    func prepareRequest(for sourceURL: URL, displayName: String) -> Request {
        let referenceItem = DropImportCoordinator.makeFileBackedItem(
            for: sourceURL,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        return Request(sourceURL: sourceURL,
                       displayName: displayName,
                       referenceItem: referenceItem)
    }

    /// Backward-compatible synchronous entry point used by focused service
    /// tests. Production drop handling calls this overload on a detached task.
    func makeCutItem(for sourceURL: URL, displayName: String) -> Outcome {
        makeCutItem(for: prepareRequest(for: sourceURL, displayName: displayName))
    }

    /// Moves one file or folder. No path deletes anything but the copy; on
    /// failure the original is untouched.
    func makeCutItem(for request: Request) -> Outcome {
        let sourceURL = request.sourceURL
        let displayName = request.displayName
        let referenceItem = request.referenceItem

        guard !isContainedInAppContainer(sourceURL) else {
            return .fallbackToReference(referenceItem, .sourceInsideContainer)
        }

        // 2. Copy into managed storage, within the security scope of the source's
        //    bookmark (the drop grants access; same as the regular import path).
        let destination: URL
        do {
            destination = try tempFileService.uniqueFileURL(suggestedName: displayName)
        } catch {
            logger.error("Cut move: failed to allocate managed file URL for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }
        do {
            try bookmarkService.withSecurityScopedAccess(to: sourceURL) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
        } catch {
            logger.error("Cut move: copy failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination) // remove the partial copy
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        // 3. Verify the copy.
        guard FileManager.default.fileExists(atPath: destination.path) else {
            logger.error("Cut move: managed copy missing after copy for \(sourceURL.path, privacy: .public)")
            return .fallbackToReference(referenceItem, .copyFailed)
        }

        var item = DropImportCoordinator.makeFileBackedItem(
            for: destination,
            displayName: displayName,
            bookmarkService: bookmarkService,
            logger: logger
        )
        item.isCut = true
        do {
            try managedMoveJournal.createPrepared(referenceItem: referenceItem,
                                                  managedItem: item)
        } catch {
            logger.error("Cut move: failed to create recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .transactionFailed)
        }

        let resultingTrashURL: URL?
        do {
            resultingTrashURL = try trashOriginal(sourceURL)
        } catch {
            logger.error("Cut move: trash failed for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? managedMoveJournal.remove(id: item.id)
            try? FileManager.default.removeItem(at: destination)
            return .fallbackToReference(referenceItem, .trashFailed)
        }

        do {
            try managedMoveJournal.markOriginalTrashed(id: item.id,
                                                       resultingURL: resultingTrashURL)
        } catch {
            logger.error("Cut move: failed to advance recovery transaction for \(sourceURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // 7. Success: the item points at the managed copy. The transaction may be
        //    deleted only after the caller has saved it in the shelf snapshot.
        return .moved(item)
    }

    private func isContainedInAppContainer(_ url: URL) -> Bool {
        url.isContained(in: containerURL)
    }
}
