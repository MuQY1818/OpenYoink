import AppKit
import OSLog

@MainActor
final class FilePromiseReceiver {
    private let tempFileService: TempFileService
    private let bookmarkService: BookmarkService
    private let pendingImportJournal: PendingImportJournal
    private let transferStore: TransferStore
    private let operationQueue: OperationQueue
    private let logger = Log.make(category: "FilePromiseReceiver")

    init(tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         pendingImportJournal: PendingImportJournal,
         transferStore: TransferStore = TransferStore()) {
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.pendingImportJournal = pendingImportJournal
        self.transferStore = transferStore
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "com.weijue.OpenYoink.FilePromiseReceive"
        // Promise writes run in the background at user-initiated QoS.
        self.operationQueue.qualityOfService = .userInitiated
    }

    func receivePromises(from pasteboard: NSPasteboard,
                         taskID: UUID,
                         onItemReady: @escaping @MainActor (ShelfItem) -> Bool) -> Int {
        guard let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !receivers.isEmpty else {
            return 0
        }

        var dispatched = 0
        // （NSFilePromiseReceiver.h:25All file promisesReceiver's in a drag

        let stagingURL: URL
        do {
            stagingURL = try tempFileService.createPromiseStagingDirectory()
        } catch {
            logger.error("Failed to create promise staging directory: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        transferStore.beginImport(id: taskID, expectedCount: nil)
        var expectedFileCount = 0
        let reportSuccess: @MainActor (ShelfItem, UUID) -> Void = {
            [transferStore, pendingImportJournal, logger] item, recoveryID in
            if onItemReady(item) {
                do {
                    try pendingImportJournal.remove(id: recoveryID)
                } catch {
                    // The shelf item is already durable. Keeping a stale
                    // record is safe and startup reconciliation removes it.
                    logger.error("Failed to clear completed pending import \(recoveryID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            } else {
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .persistenceFailed,
                        itemName: item.displayName,
                        recoveryAction: .openStorageRecovery
                    )
                )
            }
        }
        let reportFailure: @MainActor (String?, RecoveryAction) -> Void = {
            [transferStore] itemName, recoveryAction in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .promiseReceiveFailed,
                    itemName: itemName,
                    recoveryAction: recoveryAction
                )
            )
        }
        for receiver in receivers {
            // `fileTypes` is valid only within the drag session; copy it now.
            let promisedTypes = receiver.fileTypes
            dispatched += 1
            // The callback runs on the background queue: capture only Sendable
            // services and values, never the main-actor `self`, and hop back with a
            // Task. The closure must be explicitly `@Sendable` (SE-0420: @Sendable
            // closures are nonisolated); otherwise a closure formed on the main actor
            // inherits its isolation and the background call traps in
            // `_dispatch_assert_queue_fail` (seen when dragging GIFs from a browser).
            receiver.receivePromisedFiles(
                atDestination: stagingURL,
                options: [:],
                operationQueue: operationQueue
            ) { @Sendable [tempFileService, bookmarkService, pendingImportJournal, logger] fileURL, error in
                Self.handleMaterializedPromise(
                    fileURL: fileURL,
                    error: error,
                    promisedTypes: promisedTypes,
                    tempFileService: tempFileService,
                    bookmarkService: bookmarkService,
                    pendingImportJournal: pendingImportJournal,
                    logger: logger,
                    completion: { item, recoveryID in
                        Task { @MainActor in
                            reportSuccess(item, recoveryID)
                        }
                    },
                    failure: { recoveryAction in
                        Task { @MainActor in
                            reportFailure(fileURL.lastPathComponent, recoveryAction)
                        }
                    }
                )
            }
            // `fileNames` becomes available after the promise is called in and
            // is a better count than `fileTypes` for legacy multi-file promises.
            // Keep one as the conservative minimum so cancellation still ends
            // the batch when a source reports no names.
            expectedFileCount += max(receiver.fileNames.count, 1)
        }
        transferStore.setExpectedCount(expectedFileCount, for: taskID)
        return dispatched
    }

    /// Handles a finished materialization (nonisolated, on the operation queue).
    /// Success: move to the top of the materialized directory, infer the kind,
    /// bookmark, complete. Failure: log and call `failure` (an inline notice).
    /// Fires per file, so the shared staging directory is never touched.
    nonisolated static func handleMaterializedPromise(
        fileURL: URL?,
        error: Error?,
        promisedTypes: [String],
        tempFileService: TempFileService,
        bookmarkService: BookmarkService,
        pendingImportJournal: PendingImportJournal,
        logger: Logger,
        completion: (ShelfItem, UUID) -> Void,
        failure: (RecoveryAction) -> Void
    ) {
        if let error {
            logger.error("File promise materialization failed: \(error.localizedDescription, privacy: .public)")
            failure(.dragAgainFromSource)
            return
        }
        guard let fileURL else {
            logger.error("File promise delivered neither a file URL nor an error; dropping this receiver")
            failure(.dragAgainFromSource)
            return
        }

        var recoveryRecord: PendingImportJournal.Record?
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileURL.lastPathComponent)
            // This is the crash-safety boundary: both possible payload paths
            // are durable before the move begins.
            let record = try pendingImportJournal.create(
                stagingURL: fileURL,
                destinationURL: destination,
                displayName: fileURL.lastPathComponent,
                promisedTypeIdentifiers: promisedTypes
            )
            recoveryRecord = record
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let bookmark = try bookmarkService.createBookmark(for: destination)
            let item = ShelfItem(
                id: record.id,
                kind: DropImportCoordinator.inferFileKind(
                    for: destination,
                    promisedTypeIdentifiers: promisedTypes
                ),
                path: destination.path,
                bookmark: bookmark,
                // Display the original file name the source provided, without the UUID prefix.
                displayName: record.displayName
            )
            completion(item, record.id)
        } catch {
            logger.error("Failed to finalize materialized promise \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            failure(recoveryRecord == nil ? .dragAgainFromSource : .openStorageRecovery)
        }
    }
}
