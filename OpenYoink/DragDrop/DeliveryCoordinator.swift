import AppKit
import OSLog
import SwiftUI

/// the AppKit session result; a managed cut item leaves the shelf only once
/// the target accepted the session *and* its file promise was written. The
/// session snapshots also drive failure recovery and runtime file leases.
@MainActor
final class DeliveryCoordinator {
    private enum PromiseState {
        case notRequested
        case requested
        case delivered(URL)
        case failed
    }

    private struct PendingItem {
        let item: ShelfItem
        let insertionIndex: Int
        let supportsFilePromise: Bool
        var promiseState: PromiseState
    }

    private struct PendingSession {
        let id: UUID
        let startedAt: Date
        let orderedItemIDs: [UUID]
        var itemsByID: [UUID: PendingItem]
        var accepted: Bool?
    }

    private var sessions: [UUID: PendingSession] = [:]
    private var latestSessionByItemID: [UUID: UUID] = [:]

    private let store: ShelfStore
    private let recents: RecentItemsService
    private let tempFileService: TempFileService
    private let transferStore: TransferStore
    private let logger = Log.make(category: "Delivery")

    init(store: ShelfStore,
         recents: RecentItemsService,
         tempFileService: TempFileService,
         transferStore: TransferStore) {
        self.store = store
        self.recents = recents
        self.tempFileService = tempFileService
        self.transferStore = transferStore
    }

    func noteSessionBegan(id: UUID, contents: DragOutContents) {
        let flattened = contents.items.flattened
            .filter(DragPayloadBuilder.canMakePasteboardWriter)
        var itemsByID: [UUID: PendingItem] = [:]
        var orderedItemIDs: [UUID] = []
        for item in flattened where itemsByID[item.id] == nil {
            let strategy = DragPayloadBuilder.strategy(for: item)
            let supportsPromise = item.isCut
                && (strategy == .fileBacked || strategy == .fileBackedImage)
            itemsByID[item.id] = PendingItem(
                item: item,
                insertionIndex: insertionIndex(for: item.id),
                supportsFilePromise: supportsPromise,
                promiseState: .notRequested
            )
            orderedItemIDs.append(item.id)
            latestSessionByItemID[item.id] = id
        }
        guard !orderedItemIDs.isEmpty else { return }
        sessions[id] = PendingSession(id: id,
                                      startedAt: Date(),
                                      orderedItemIDs: orderedItemIDs,
                                      itemsByID: itemsByID,
                                      accepted: nil)
        transferStore.beginExport(id: id, itemIDs: orderedItemIDs)
        trimRetainedSessions()
    }

    func notePromiseRequested(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .notRequested:
            pending.promiseState = .requested
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
            transferStore.recordExportPromiseRequested(taskID: sessionID, itemID: itemID)
        case .requested, .delivered, .failed:
            break
        }
    }

    func noteDelivered(sessionID: UUID, itemID: UUID, destination: URL) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .delivered(destination)
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        transferStore.recordExportDelivered(taskID: sessionID, itemID: itemID)
        if pending.item.isCut {
            finalizeManagedItem(pending.item, destination: destination)
        }
    }

    func noteFailed(sessionID: UUID, itemID: UUID) {
        guard latestSessionByItemID[itemID] == sessionID,
              var session = sessions[sessionID],
              var pending = session.itemsByID[itemID],
              pending.supportsFilePromise else { return }
        switch pending.promiseState {
        case .delivered, .failed:
            return
        case .notRequested, .requested:
            pending.promiseState = .failed
            session.itemsByID[itemID] = pending
            sessions[sessionID] = session
        }
        guard session.accepted == true else { return }
        registerFailure(pending.item,
                        insertionIndex: pending.insertionIndex,
                        sessionID: sessionID)
    }

    func noteSessionEnded(id: UUID, accepted: Bool) {
        guard var session = sessions[id] else { return }
        guard accepted else {
            transferStore.finishExportSession(taskID: id, accepted: false)
            discardSession(id)
            return
        }

        session.accepted = true
        sessions[id] = session
        let directlyAccepted = Set(session.orderedItemIDs.compactMap { itemID -> UUID? in
            guard let pending = session.itemsByID[itemID] else { return nil }
            if !pending.supportsFilePromise { return itemID }
            if !pending.item.isCut, case .notRequested = pending.promiseState {
                return itemID
            }
            return nil
        })
        transferStore.finishExportSession(taskID: id,
                                          accepted: true,
                                          directlyAcceptedItemIDs: directlyAccepted)

        // Promise callbacks may have beaten the AppKit session callback.
        for itemID in session.orderedItemIDs {
            guard let pending = session.itemsByID[itemID] else { continue }
            switch pending.promiseState {
            case .delivered(let destination):
                transferStore.recordExportDelivered(taskID: id, itemID: itemID)
                if pending.item.isCut {
                    finalizeManagedItem(pending.item, destination: destination)
                }
            case .failed:
                registerFailure(pending.item,
                                insertionIndex: pending.insertionIndex,
                                sessionID: id)
            case .notRequested, .requested:
                break
            }
        }
    }

    /// Brackets an AppKit dragging session so the shelf can hide its transfer
    /// strip mid-drag. Call `noteDragSessionStarted` only right before
    /// `beginDraggingSession`; the NSDraggingSource end callback balances it.
    func noteDragSessionStarted() {
        transferStore.noteDragSessionStarted()
    }

    func noteDragSessionEnded() {
        transferStore.noteDragSessionEnded()
    }

    /// Runtime file leases used by Storage settings. A direct drop can remove
    /// a materialized card before a target makes a late promise request; these
    /// snapshots prevent manual cleanup from deleting the only retained bytes.
    var protectedMaterializedPaths: Set<String> {
        let undelivered = sessions.values
            .filter { $0.accepted == true }
            .flatMap(\.itemsByID.values)
            .filter { pending in
                if case .delivered = pending.promiseState { return false }
                return !containsItem(pending.item.id)
            }
            .map(\.item)
        return undelivered.materializedPaths(in: tempFileService.directoryURL)
    }

    private func registerFailure(_ item: ShelfItem,
                                 insertionIndex: Int,
                                 sessionID: UUID) {
        if !containsItem(item.id) {
            store.add(item, at: insertionIndex)
        }
        transferStore.recordExportFailure(
            taskID: sessionID,
            itemID: item.id,
            failure: TransferFailure(
                reason: .deliveryFailed,
                itemName: item.displayName,
                recoveryAction: .retryByDraggingOut(itemID: item.id)
            )
        )
    }

    private func finalizeManagedItem(_ item: ShelfItem, destination: URL) {
        store.invalidateUndoForDeliveredItem(item.id)
        if let path = item.path {
            do {
                try tempFileService.removeMaterializedFile(at: URL(fileURLWithPath: path))
            } catch {
                logger.error("Failed to delete managed cut file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if store.item(withID: item.id) != nil {
            store.remove(ids: [item.id])
        } else if let stack = store.items.first(where: {
            ($0.children ?? []).contains(id: item.id)
        }) {
            store.removeChild(item.id, fromStack: stack.id)
        }
        var entry = item
        entry.path = destination.path
        recents.record([entry])
    }

    private func insertionIndex(for itemID: UUID) -> Int {
        if let index = store.index(ofItemWithID: itemID) {
            return index
        }
        return store.items.firstIndex { ($0.children ?? []).contains(id: itemID) }
            ?? store.items.count
    }

    private func containsItem(_ itemID: UUID) -> Bool {
        store.items.contains(id: itemID)
    }

    private func discardSession(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        for itemID in session.orderedItemIDs where latestSessionByItemID[itemID] == id {
            latestSessionByItemID.removeValue(forKey: itemID)
        }
    }

    /// Bound runtime snapshots while keeping current/incomplete sessions. The
    /// oldest completed ordinary sessions are the first candidates; active
    /// managed deliveries are never evicted.
    private func trimRetainedSessions() {
        guard sessions.count > 128 else { return }
        let removable = sessions.values
            .filter { session in
                guard session.accepted != nil else { return false }
                return session.itemsByID.values.allSatisfy { pending in
                    !pending.item.isCut && {
                        switch pending.promiseState {
                        case .requested: false
                        case .notRequested, .delivered, .failed: true
                        }
                    }()
                }
            }
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(sessions.count - 128)
            .map(\.id)
        for id in removable {
            discardSession(id)
        }
    }
}

// MARK: - SwiftUI environment
