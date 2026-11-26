import AppKit
import OSLog
import UniformTypeIdentifiers

/// The outcome of one import: items available now, plus how many are still
/// being materialized in the background.
struct DropImportResult: Equatable, Sendable {
    /// Items ready for the shelf right away (file URLs, URLs, text).
    var items: [ShelfItem]
    /// Materializations dispatched to the background that will arrive through
    /// `onAsyncItemReady` (file promises, image data).
    var pendingMaterializations: Int

    /// Whether anything was handled; the return value of `performDragOperation`.
    var handled: Bool { !items.isEmpty || pendingMaterializations > 0 }

    static let unhandled = DropImportResult(items: [], pendingMaterializations: 0)
}

/// A plain drop adds a reference; a ⌘-drop moves the file in (the original
/// goes to the Trash, a managed copy joins the shelf). ⌘ only applies to
/// file URLs: promises, text, URLs and image data have no original file.
enum DropInMode: String, Equatable, Sendable {
    /// Keep a reference; the original stays where it is (default).
    case copy
    /// Keep a managed copy and move the original to the Trash.
    case move
}

/// Dispatches a pasteboard to file promises, file URLs, images, web URLs,
/// or text in priority order. A per-item fallback handles other representations.
@MainActor
final class DropImportCoordinator {
    /// Default display name of a materialized image (the file on disk carries
    /// a UUID prefix).
    nonisolated static var materializedImageDisplayName: String {
        String(localized: "Dropped Image.png")
    }

    /// Called synchronously on the main actor whenever `importItems` handled
    /// something (drops and clipboard saves alike), so a drag that dropped
    /// content keeps its automatically shown shelf open.
    var onImportHandled: (@MainActor () -> Void)?

    var isActiveTutorialToken: (@MainActor (String) -> Bool)?
    var onTutorialItemsImported: (@MainActor (String, [ShelfItem]) -> Void)?

    private let bookmarkService: BookmarkService

    private let noticeCenter: ShelfNoticeModel
    /// Orchestrates ⌘-drop moves: copy → verify → trash → cut item.
    let cutMoveService: CutMoveService
    /// Managed-move recovery records. A record is deleted by
    /// `markManagedMoveCommitted` only after the item was saved synchronously.
    let managedMoveJournal: ManagedMoveJournal
    /// promised files are journaled before leaving staging and remain
    /// retryable until their ShelfItem is synchronously persisted.
    let pendingImportJournal: PendingImportJournal
    /// runtime-only batch status rendered by ShelfActivityStrip.
    let transferStore: TransferStore
    private let tempFileService: TempFileService
    private let promiseReceiver: FilePromiseReceiver
    private let logger = Log.make(category: "DropImport")

    convenience init(bookmarkService: BookmarkService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel = ShelfNoticeModel(),
         managedMoveJournal: ManagedMoveJournal? = nil,
         pendingImportJournal: PendingImportJournal? = nil,
         transferStore: TransferStore? = nil,
         cutMoveService: CutMoveService? = nil) {
        let transferStore = transferStore ?? TransferStore()
        let journal = managedMoveJournal ?? cutMoveService?.managedMoveJournal
            ?? ManagedMoveJournal(directoryURL: tempFileService.directoryURL.deletingLastPathComponent())
        let pendingJournal = pendingImportJournal ?? PendingImportJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent(),
            managedDirectoryURL: tempFileService.directoryURL
        )
        self.init(
            bookmarkService: bookmarkService, tempFileService: tempFileService,
            noticeCenter: noticeCenter, managedMoveJournal: journal,
            pendingImportJournal: pendingJournal, transferStore: transferStore,
            cutMoveService: cutMoveService ?? CutMoveService(
                tempFileService: tempFileService, bookmarkService: bookmarkService, managedMoveJournal: journal
            ),
            promiseReceiver: FilePromiseReceiver(
                tempFileService: tempFileService, bookmarkService: bookmarkService,
                pendingImportJournal: pendingJournal, transferStore: transferStore
            )
        )
    }

    init(bookmarkService: BookmarkService, tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel, managedMoveJournal: ManagedMoveJournal,
         pendingImportJournal: PendingImportJournal, transferStore: TransferStore,
         cutMoveService: CutMoveService, promiseReceiver: FilePromiseReceiver) {
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        self.noticeCenter = noticeCenter
        self.managedMoveJournal = managedMoveJournal
        self.pendingImportJournal = pendingImportJournal
        self.transferStore = transferStore
        self.cutMoveService = cutMoveService
        self.promiseReceiver = promiseReceiver
    }

    // MARK: - Entry point

    /// ⌘ with file URLs on the pasteboard moves; everything else copies, since
    /// other content has no original file. `modifiers` are the live
    /// `NSEvent.modifierFlags` of the drag session.
    nonisolated static func dropMode(for pasteboard: NSPasteboard,
                                     modifiers: NSEvent.ModifierFlags) -> DropInMode {
        guard modifiers.contains(.command),
              PasteboardTypes.supports(.fileURL, types: pasteboard.types ?? []) else {
            return .copy
        }
        return .move
    }

    /// Imports one drop. Synchronous items are returned; promises and image
    /// data materialize in the background and arrive one by one through
    /// `onAsyncItemReady` on the main actor. Calls `onImportHandled` when
    /// anything was handled. With `.move`, file URLs go through the cut path.
    @discardableResult
    func importItems(from pasteboard: NSPasteboard,
                     mode: DropInMode = .copy,
                     onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onPromisedItemReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let batchID = UUID()
        let tutorialToken = activeTutorialToken(in: pasteboard)
        let wrappedAsyncReady: @MainActor (ShelfItem) -> Void = { [weak self] item in
            onAsyncItemReady(item)
            guard let self, let tutorialToken else { return }
            self.onTutorialItemsImported?(tutorialToken, [item])
        }
        let wrappedPromisedReady: @MainActor (ShelfItem) -> Bool = { [weak self] item in
            guard let onPromisedItemReady else {
                wrappedAsyncReady(item)
                return true
            }
            let committed = onPromisedItemReady(item)
            if committed, let self, let tutorialToken {
                self.onTutorialItemsImported?(tutorialToken, [item])
            }
            return committed
        }
        let result = dispatchImport(from: pasteboard,
                                    batchID: batchID,
                                    mode: mode,
                                    onManagedMoveReady: onManagedMoveReady,
                                    onPromisedItemReady: wrappedPromisedReady,
                                    onAsyncItemReady: wrappedAsyncReady)
        if result.handled {
            onImportHandled?()
        }
        return result
    }

    /// Explicit pasteboard action: no fallback to files, links, or text.
    func importClipboardImages(from pasteboard: NSPasteboard,
                               onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        let pending = scheduleImageMaterialization(
            from: pasteboard, taskID: UUID(),
            displayName: String(localized: "Clipboard Image.png"),
            recoveryAction: .dismiss, onItemReady: onItemReady
        )
        if pending > 0 { onImportHandled?() }
        return pending
    }

    /// Lets a destination tell the current onboarding exercise from a shelf
    /// card dropped back. A token mismatch is always refused.
    func acceptsInternalTutorialDrag(_ pasteboard: NSPasteboard) -> Bool {
        activeTutorialToken(in: pasteboard) != nil
    }

    func noteSynchronousTutorialImport(from pasteboard: NSPasteboard,
                                       items: [ShelfItem]) {
        guard !items.isEmpty, let token = activeTutorialToken(in: pasteboard) else { return }
        onTutorialItemsImported?(token, items)
    }

    private func activeTutorialToken(in pasteboard: NSPasteboard) -> String? {
        guard let token = pasteboard.string(forType: PasteboardTypes.tutorialSession),
              !token.isEmpty,
              isActiveTutorialToken?(token) == true else {
            return nil
        }
        return token
    }

    /// The dispatch itself, below `importItems`, which fires the callbacks.
    private func dispatchImport(from pasteboard: NSPasteboard,
                                batchID: UUID,
                                mode: DropInMode,
                                onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
                                onPromisedItemReady: @escaping @MainActor (ShelfItem) -> Bool,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let types = pasteboard.types ?? []

        // 1. File promises first: the highest-quality representation.
        if PasteboardTypes.supports(.filePromise, types: types) {
            let pending = promiseReceiver.receivePromises(from: pasteboard,
                                                           taskID: batchID,
                                                           onItemReady: onPromisedItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
            // Promise types declared but no receiver readable: fall through.
        }

        // 2. File URLs (Finder files and folders, other apps' file representations).
        if PasteboardTypes.supports(.fileURL, types: types) {
            if mode == .move {
                // copy/trash can be expensive. Capture bookmarks while
                // the pasteboard grant is active, then perform each transaction
                // serially on a detached task.
                let pending = scheduleCutMovedItems(
                    from: pasteboard,
                    taskID: batchID,
                    onManagedMoveReady: onManagedMoveReady,
                    onItemReady: onAsyncItemReady
                )
                if pending > 0 {
                    return DropImportResult(items: [], pendingMaterializations: pending)
                }
            } else {
                let items = fileURLItems(from: pasteboard)
                if !items.isEmpty {
                    return DropImportResult(items: items, pendingMaterializations: 0)
                }
            }
        }

        // 3. Image data without a file URL: materialize a PNG.
        if PasteboardTypes.preferredImageType(in: types) != nil {
            let pending = scheduleImageMaterialization(from: pasteboard,
                                                       taskID: batchID,
                                                       displayName: Self.materializedImageDisplayName,
                                                       recoveryAction: .dragAgainFromSource,
                                                       onItemReady: onAsyncItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
        }

        // 4. URL
        if PasteboardTypes.supports(.url, types: types) {
            let items = urlItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 5. Text (plain text only).
        if PasteboardTypes.supports(.text, types: types) {
            let items = textItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 6. Fallback chain: nothing came out of the main chain.
        let fallback = fallbackImport(from: pasteboard,
                                      taskID: batchID,
                                      onAsyncItemReady: onAsyncItemReady)
        guard !fallback.items.isEmpty || fallback.pending > 0 else {
            logger.warning("Drop contained no importable content; declared types: \(types.map(\.rawValue), privacy: .public)")
            noticeCenter.show(String(localized: "That content can't be added to the shelf yet."))
            return .unhandled
        }
        // A heterogeneous fallback drop can contain synchronous rich text/URL
        // items alongside background materializations. Once a runtime batch
        // exists, include those already-ready items in the same factual total.
        if fallback.pending > 0, !fallback.items.isEmpty {
            transferStore.extendImport(id: batchID, by: fallback.items.count)
            for item in fallback.items {
                transferStore.recordSuccess(taskID: batchID, itemID: item.id)
            }
        }
        return DropImportResult(items: fallback.items, pendingMaterializations: fallback.pending)
    }

    private func fallbackImport(from pasteboard: NSPasteboard,
                                taskID: UUID,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void)
        -> (items: [ShelfItem], pending: Int) {
        var items: [ShelfItem] = []
        var pending = 0

        // a. text/uri-list. At the item level this flavor is bridged to a dyn.*
        //    type that `string(forType:)` can't read, so it is read from the
        //    whole pasteboard by its raw flavor name, one URI per line (lines
        //    starting with # are comments).
        let urlListItems = urlListVariantItems(from: pasteboard)
        items.append(contentsOf: urlListItems)

        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            // With URLs from the uri-list, skip items made only of bridged dyn.*
            // types: they are the uri-list's own projection and would duplicate it
            // as .dat or text items.
            if !urlListItems.isEmpty,
               pasteboardItem.types.allSatisfy({ $0.rawValue.hasPrefix("dyn.") }) {
                continue
            }

            if let richItem = richTextFileItem(from: pasteboardItem) {
                items.append(richItem)
                continue
            }
            // c. Generic data, best type first (tiers in
            //    `PasteboardTypes.materializationCandidates`), written in the background.
            if scheduleDataMaterialization(from: pasteboardItem,
                                           taskID: taskID,
                                           onItemReady: onAsyncItemReady) {
                pending += 1
                continue
            }
            // d. Any type that reads as non-empty meaningful text → a text item.
            if let textItem = fallbackTextItem(from: pasteboardItem) {
                items.append(textItem)
                continue
            }
            // e. Log every failed item; never fail silently.
            logger.info("Fallback import skipped an item; declared types: \(pasteboardItem.types.map(\.rawValue), privacy: .public)")
        }
        return (items, pending)
    }

    /// Branch a: one URL item per line; an invalid line doesn't affect the
    /// others. Read at the pasteboard level (see `fallbackImport`).
    private func urlListVariantItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard (pasteboard.types ?? []).contains(PasteboardTypes.uriList),
              let payload = pasteboard.string(forType: PasteboardTypes.uriList),
              !payload.isEmpty else {
            return []
        }
        return payload.components(separatedBy: .newlines).compactMap { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#"),
                  let url = URL(string: candidate), url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? candidate,
                             urlString: candidate)
        }
    }

    /// Branch b: an HTML/RTF-only item becomes an .html/.rtf file (kind
    /// `.file`, still rich text when dragged out), named after the first line
    /// of its plain text or a localized fallback. HTML parsing must stay on the
    /// main thread; don't move it into a background task.
    private func richTextFileItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        if pasteboardItem.types.contains(PasteboardTypes.html),
           let data = pasteboardItem.data(forType: PasteboardTypes.html), !data.isEmpty {
            let plainText = NSAttributedString(html: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "html",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped HTML"))
        }
        if pasteboardItem.types.contains(PasteboardTypes.rtf),
           let data = pasteboardItem.data(forType: PasteboardTypes.rtf), !data.isEmpty {
            let plainText = NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "rtf",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped RTF"))
        }
        return nil
    }

    /// Writes rich text for branch b. A failed write is logged and noticed,
    /// and returns nil so the later branches (string fallback) still run.
    private func writeRichTextFile(data: Data, fileExtension: String,
                                   plainText: String, fallbackBaseName: String) -> ShelfItem? {

        let stripped = plainText.replacingOccurrences(of: "\u{FFFC}", with: "")
        let hasText = !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let baseName = hasText ? Self.displayName(forText: stripped) : fallbackBaseName
        let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
            try data.write(to: destination, options: .atomic)
            return Self.makeFileBackedItem(for: destination,
                                           displayName: fileName,
                                           forcedKind: .file,
                                           bookmarkService: bookmarkService,
                                           logger: logger)
        } catch {
            logger.error("Failed to materialize dropped rich text: \(error.localizedDescription, privacy: .public)")
            noticeCenter.show(String(localized: "Couldn't add the dropped item."))
            return nil
        }
    }

    /// Branch c: the first candidate type (in tier order) with non-empty data
    /// is written in the background, like image materialization; kind follows
    /// the UTI (image → `.image`, else `.file`). Returns whether it dispatched.
    private func scheduleDataMaterialization(from pasteboardItem: NSPasteboardItem,
                                             taskID: UUID,
                                             onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Bool {
        for candidate in PasteboardTypes.materializationCandidates(in: pasteboardItem.types) {
            // A tier-3 (dynamic, bridged, generic) type that reads as meaningful text
            // is more useful as text than as .dat; leave it to branch d (for example
            // utf8-external-plain-text, which has no UTType). The meaningful-text
            // check matters: `string(forType:)` also decodes binary data lossily
            // ([1,2,3] → "\u{1}\u{2}\u{3}").
            if candidate.tier == 3,
               let text = pasteboardItem.string(forType: candidate.type),
               Self.isMeaningfulText(text) {
                continue
            }
            let type = candidate.type
            guard let data = pasteboardItem.data(forType: type), !data.isEmpty else { continue }
            let fileExtension = PasteboardTypes.materializationFileExtension(for: type)
            let baseName = PasteboardTypes.materializedDisplayBaseName(for: type)
            let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
            let kind: ItemKind = UTType(type.rawValue)?.conforms(to: .image) == true ? .image : .file
            transferStore.extendImport(id: taskID, by: 1)
            let reportFailure: @MainActor () -> Void = { [transferStore] in
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .materializationFailed,
                        itemName: fileName,
                        recoveryAction: .dragAgainFromSource
                    )
                )
            }
            let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
                onItemReady(item)
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            }
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
                    try data.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: fileName,
                                                       forcedKind: kind,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    logger.error("Failed to materialize dropped data (\(type.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
            return true
        }
        return false
    }

    /// Branch d: the first type that reads as meaningful text becomes a text
    /// item. `string(forType:)` returns nil for non-string types and decodes
    /// binary lossily; `isMeaningfulText` rejects the garbage.
    private func fallbackTextItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        for type in pasteboardItem.types {
            guard let text = pasteboardItem.string(forType: type),
                  Self.isMeaningfulText(text) else { continue }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        return nil
    }

    /// Non-empty and free of control characters (whitespace excepted). Without
    /// this, `string(forType:)`'s lossy decoding of binary data
    /// ([0x01,0x02,0x03] → "\u{1}\u{2}\u{3}") would become a garbage text item
    /// instead of a .dat file.
    nonisolated static func isMeaningfulText(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let controls = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        return string.rangeOfCharacter(from: controls) == nil
    }

    /// Strips path separators from a materialized file name: a "/" in the
    /// first line would make `TempFileService` cut off the front of the name.
    nonisolated static func sanitizedFileNameComponent(_ name: String) -> String {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "Dropped Item") : sanitized
    }

    // MARK: - fileURL

    private func fileURLItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        pasteboard.fileURLs().map { Self.makeFileBackedItem(for: $0, displayName: $0.lastPathComponent, bookmarkService: bookmarkService, logger: logger) }
    }

    private func scheduleCutMovedItems(
        from pasteboard: NSPasteboard,
        taskID: UUID,
        onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
        onItemReady: @escaping @MainActor (ShelfItem) -> Void
    ) -> Int {
        let urls = pasteboard.fileURLs()
        let service = cutMoveService
        let requests = urls.map {
            service.prepareRequest(for: $0, displayName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return 0 }
        transferStore.beginImport(
            id: taskID,
            expectedCount: requests.count,
            safetyMessage: String(localized: "Managed copies are protected while originals move to the Trash.")
        )
        let transferStore = transferStore
        Task.detached(priority: .userInitiated) {
            for request in requests {
                switch service.makeCutItem(for: request) {
                case .moved(let item):
                    await MainActor.run {
                        let committed: Bool
                        if let onManagedMoveReady {
                            committed = onManagedMoveReady(item)
                        } else {
                            // Defensive compatibility path. The journal stays
                            // until startup reconciliation if the caller does
                            // not provide the commit-aware callback.
                            onItemReady(item)
                            committed = true
                        }
                        if committed {
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .persistenceFailed,
                                    itemName: request.displayName,
                                    recoveryAction: .openStorageRecovery,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                case .fallbackToReference(let item, let reason):
                    await MainActor.run {
                        onItemReady(item)
                        if reason == .sourceInsideContainer {
                            // The item was intentionally downgraded to a normal
                            // reference, so the batch still succeeded.
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .managedMoveFellBackToReference,
                                    itemName: request.displayName,
                                    recoveryAction: .dismiss,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                }
            }
        }
        return requests.count
    }

    /// Deletes the recovery transaction after the caller has synchronously
    /// committed `item` to the shelf snapshot. Failure is safe: the record is
    /// reconciled on the next launch and continues protecting its managed path.
    func markManagedMoveCommitted(itemID: UUID) {
        do {
            try managedMoveJournal.remove(id: itemID)
        } catch {
            logger.error("Failed to finish managed move transaction \(itemID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Image data

    private func scheduleImageMaterialization(from pasteboard: NSPasteboard,
                                              taskID: UUID,
                                              displayName: String,
                                              recoveryAction: RecoveryAction,
                                              onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        let payloads: [(type: NSPasteboard.PasteboardType, data: Data)] =
            (pasteboard.pasteboardItems ?? []).compactMap { item in
                guard let type = PasteboardTypes.preferredImageType(in: item.types),
                      let data = item.data(forType: type), !data.isEmpty else {
                    return nil
                }
                return (type, data)
            }

        guard !payloads.isEmpty else { return 0 }
        transferStore.beginImport(id: taskID, expectedCount: payloads.count)
        let reportFailure: @MainActor () -> Void = { [transferStore] in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .materializationFailed,
                    itemName: displayName,
                    recoveryAction: recoveryAction
                )
            )
        }
        let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
            onItemReady(item)
            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
        }
        for payload in payloads {
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    guard let pngData = Self.pngData(from: payload.data, type: payload.type) else {
                        throw DropImportError.imageConversionFailed
                    }
                    let destination = try tempFileService.uniqueFileURL(suggestedName: displayName)
                    try pngData.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: displayName,
                                                       forcedKind: .image,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    // Never crash or fail silently: log and notice; the drop still counts as handled.
                    logger.error("Failed to materialize image data: \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
        }
        return payloads.count
    }

    private nonisolated static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == PasteboardTypes.png {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - URL

    private func urlItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(PasteboardTypes.url),
                  let string = item.string(forType: PasteboardTypes.url),
                  let url = URL(string: string),
                  url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? string,
                             urlString: string)
        }
    }

    // MARK: - Text

    private func textItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ShelfItem? in
            guard let text = item.string(forType: .string), !text.isEmpty else { return nil }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        // Some sources offer a string only on the pasteboard as a whole.
        if items.isEmpty,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)]
        }
        return items
    }

    /// First line truncated to 60 characters; blank text falls back to "Text".
    static func displayName(forText text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return String(localized: "Text") }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Shared file-backed item construction

    nonisolated static func makeFileBackedItem(for url: URL,
                                               displayName: String,
                                               forcedKind: ItemKind? = nil,
                                               promisedTypeIdentifiers: [String] = [],
                                               bookmarkService: BookmarkService,
                                               logger: Logger) -> ShelfItem {
        let kind = forcedKind ?? inferFileKind(for: url, promisedTypeIdentifiers: promisedTypeIdentifiers)
        let bookmark: Data?
        do {
            bookmark = try bookmarkService.createBookmark(for: url)
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            bookmark = nil
        }
        return ShelfItem(kind: kind, path: url.path, bookmark: bookmark, displayName: displayName)
    }

    nonisolated static func inferFileKind(for url: URL, promisedTypeIdentifiers: [String] = []) -> ItemKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            return .folder
        }
        if !url.pathExtension.isEmpty,
           let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image) ? .image : .file
        }

        let promisedTypes = Set(promisedTypeIdentifiers.compactMap(UTType.init))
        if promisedTypes.count == 1, let type = promisedTypes.first {
            if type.conforms(to: .folder), !type.conforms(to: .package) { return .folder }
            if type.conforms(to: .image) { return .image }
        }
        return .file
    }
}

/// Errors while materializing a drop.
enum DropImportError: LocalizedError {
    /// The dropped bitmap couldn't be converted to PNG.
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            String(localized: "Dropped image data could not be converted to PNG.")
        }
    }
}
