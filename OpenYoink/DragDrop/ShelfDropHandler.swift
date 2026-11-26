import AppKit

/// The one drop pipeline into the shelf, shared by the shelf panels and the
/// edge tab: which drags are accepted, copy vs. ⌘-move, and the durable
/// commit of moved and promised files.
@MainActor
struct ShelfDropHandler {
    let store: ShelfStore
    let coordinator: DropImportCoordinator
    let notices: ShelfNoticeModel

    /// Drags of our own cards are refused (dropping one back would duplicate
    /// it), except the current onboarding exercise. Any declared type is
    /// accepted: the fallback chain can materialize almost anything.
    func accepts(_ sender: NSDraggingInfo) -> Bool {
        accepts(sender.draggingPasteboard, isInternal: sender.draggingSource != nil)
    }

    func accepts(_ pasteboard: NSPasteboard, isInternal: Bool) -> Bool {
        guard !isInternal || isTutorialDrag(pasteboard) else {
            return false
        }
        return PasteboardTypes.hasImportableContent(in: pasteboard.types ?? [])
    }

    func isTutorialDrag(_ pasteboard: NSPasteboard) -> Bool {
        coordinator.acceptsInternalTutorialDrag(pasteboard)
    }

    /// Reads the live modifier keys: ⌘ moves files (never the onboarding
    /// exercise, which the app itself created).
    func mode(for pasteboard: NSPasteboard, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> DropInMode {
        guard !isTutorialDrag(pasteboard) else { return .copy }
        return DropImportCoordinator.dropMode(for: pasteboard, modifiers: modifiers)
    }

    /// Imports a drop. Synchronous items go in at `insertionIndex` (or the
    /// end); asynchronously materialized ones are appended as they finish.
    func performDrop(_ sender: NSDraggingInfo, at insertionIndex: Int? = nil) -> Bool {
        performDrop(from: sender.draggingPasteboard, isInternal: sender.draggingSource != nil, at: insertionIndex)
    }

    func performDrop(from pasteboard: NSPasteboard, isInternal: Bool, at insertionIndex: Int? = nil) -> Bool {
        guard accepts(pasteboard, isInternal: isInternal) else { return false }
        let store = store
        let coordinator = coordinator
        let result = coordinator.importItems(
            from: pasteboard,
            mode: mode(for: pasteboard),
            onManagedMoveReady: { commitManagedMove($0, store: store, coordinator: coordinator, notices: notices) },
            onPromisedItemReady: { commitPromisedItem($0, store: store, notices: notices) },
            onAsyncItemReady: { store.add($0) }
        )
        guard result.handled else { return false }
        store.add(contentsOf: result.items, at: insertionIndex)
        coordinator.noteSynchronousTutorialImport(from: pasteboard, items: result.items)
        return true
    }
}

/// The commit point of a managed move: the shelf snapshot containing the
/// item is saved synchronously before its journal record goes. If the save
/// fails the item still joins the shelf, but the record stays for recovery at
/// the next launch and keeps the managed copy protected from cleanup.
@MainActor
private func commitManagedMove(_ item: ShelfItem, store: ShelfStore, coordinator: DropImportCoordinator, notices: ShelfNoticeModel) -> Bool {
    do {
        try store.addAndPersistNow(item)
        coordinator.markManagedMoveCommitted(itemID: item.id)
        return true
    } catch {
        store.add(item)
        notices.show(String(localized: "The moved item is being kept for recovery because the shelf could not be saved immediately."))
        return false
    }
}

/// A promised file stays in `PendingImportJournal` until this synchronous
/// write succeeds. On failure it is *not* added in memory: Storage › Pending
/// Imports stays the one truthful retry path, and memory can't diverge from disk.
@MainActor
private func commitPromisedItem(_ item: ShelfItem, store: ShelfStore, notices: ShelfNoticeModel) -> Bool {
    do {
        try store.addAndPersistNow(item)
        return true
    } catch {
        notices.show(String(localized: "The received file was kept safely. Open Recovery to finish importing it."))
        return false
    }
}
