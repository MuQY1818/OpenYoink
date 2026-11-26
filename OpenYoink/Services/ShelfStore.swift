import Foundation
import Observation

/// Ordered, observable model of the shelf's contents.
///
/// Every mutation schedules a debounced save through the injected
/// `PersistenceController` (pass nil in tests to disable persistence).
/// Removing an item only drops the reference — the user's original file is
/// never deleted.
@MainActor
@Observable
final class ShelfStore {
    /// Top-level items in display order. Stack members live inside their parent
    /// item (`ShelfItem.children`) and are not part of this array.
    private(set) var items: [ShelfItem]

    /// Ids of the currently selected top-level items (multi-select).
    private(set) var selection: Set<UUID> = [] {
        didSet {
            if oldValue != selection { onSelectionDidChange?() }
        }
    }

    private let persistence: PersistenceController?
    var searchQuery = ""
    var contentFilter: ShelfContentFilter = .all
    var visibleItems: [ShelfItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { contentFilter.matches($0, query: query) }
    }
    private struct RemovalChange {
        let index: Int
        let before: ShelfItem
        let after: ShelfItem?
    }
    private var removalUndo: [[RemovalChange]] = []
    var canUndoRemoval: Bool { !removalUndo.isEmpty }
    var undoProtectedPaths: Set<String> {
        Set(removalUndo.flatMap { $0.flatMap { [$0.before].flattened.compactMap(\.path) } })
    }

    /// Only explicit card removal is undoable; delivered files are never restored.
    @discardableResult
    func removeForUser(ids: Set<UUID>) -> [ShelfItem] {
        let before = items
        let removed = remove(ids: ids)
        rememberRemoval(before: before)
        return removed
    }

    /// Keep a durable recovery copy before a bulk action can orphan managed
    /// files. If recovery cannot be written, leave the shelf unchanged.
    @discardableResult
    func removeBatchForUser(ids: Set<UUID>) throws -> [ShelfItem] {
        guard items.contains(where: { ids.contains($0.id) }) else { return [] }
        try persistence?.saveRemovalRecoverySnapshot(items)
        return removeForUser(ids: ids)
    }

    @discardableResult
    func removeChildrenForUser(ids: Set<UUID>, fromStack stackID: UUID) -> Bool {
        let before = items
        let changed = removeChildren(ids: ids, fromStack: stackID)
        if changed { rememberRemoval(before: before) }
        return changed
    }

    private func rememberRemoval(before: [ShelfItem]) {
        let changes = before.enumerated().compactMap { index, item -> RemovalChange? in
            let after = items.first { $0.id == item.id }
                ?? (item.kind == .stack ? items.first { candidate in (item.children ?? []).contains { $0.id == candidate.id } } : nil)
            return after == item ? nil : RemovalChange(index: index, before: item, after: after)
        }
        guard !changes.isEmpty else { return }
        removalUndo.append(changes)
        if removalUndo.count > 20 { removalUndo.removeFirst() }
    }

    @discardableResult
    func undoLastRemoval() -> Bool {
        guard let changes = removalUndo.popLast() else { return false }
        var restored = false
        for change in changes {
            if let after = change.after {
                guard let index = items.firstIndex(where: { $0 == after }) else { continue }
                items[index] = change.before
            } else {
                let ids = Set([change.before].flattened.map(\.id))
                guard itemRecursively(withID: change.before.id) == nil,
                      ids.allSatisfy({ itemRecursively(withID: $0) == nil }) else { continue }
                items.insert(change.before, at: min(change.index, items.count))
            }
            restored = true
        }
        if restored { persist() }
        return restored
    }

    func invalidateUndoForDeliveredItem(_ id: UUID) {
        removalUndo.removeAll { changes in
            changes.contains { [$0.before].flattened.contains { $0.id == id } }
        }
    }

    /// Called after every persisted item change (add, remove, move, stack
    /// operations, update), for the compact-height animation and hiding an empty
    /// shelf. Selection changes don't call it (they don't affect layout).
    var onItemsDidChange: (@MainActor () -> Void)?

    /// Selection controls the quick-action row and therefore affects the
    /// compact panel height even though it is never persisted.
    var onSelectionDidChange: (@MainActor () -> Void)?

    init(items: [ShelfItem] = [], persistence: PersistenceController? = nil) {
        self.items = items
        self.persistence = persistence
    }

    /// Creates a store preloaded with the persisted shelf contents.
    convenience init(persistence: PersistenceController) {
        self.init(items: persistence.loadResult().contents, persistence: persistence)
    }

    // MARK: - Queries

    /// Selected items in display order.
    var selectedItems: [ShelfItem] {
        items.filter { selection.contains($0.id) }
    }

    func item(withID id: UUID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    /// Finds a top-level item or a descendant of a stack.
    func itemRecursively(withID id: UUID) -> ShelfItem? {
        items.item(withID: id)
    }

    func index(ofItemWithID id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Adding

    /// Inserts an item at `index` (clamped to bounds), or appends when nil.
    func add(_ item: ShelfItem, at index: Int? = nil) {
        let insertionIndex = min(max(index ?? items.count, 0), items.count)
        items.insert(item, at: insertionIndex)
        persist()
    }

    /// Appends multiple items, preserving their order.
    func add(contentsOf newItems: [ShelfItem]) {
        add(contentsOf: newItems, at: nil)
    }

    /// Inserts multiple items starting at `index` (clamped to bounds),
    /// preserving their order. A nil index appends to the end.
    func add(contentsOf newItems: [ShelfItem], at index: Int?) {
        guard !newItems.isEmpty else { return }
        let insertionIndex = min(max(index ?? items.count, 0), items.count)
        items.insert(contentsOf: newItems, at: insertionIndex)
        persist()
    }

    /// Adds an item only after the resulting shelf snapshot has been written
    /// synchronously. Managed moves use this durability boundary before their
    /// crash-recovery journal can be removed.
    ///
    /// With no injected persistence (unit tests/previews), this behaves like a
    /// normal add while still avoiding a second debounced save.
    func addAndPersistNow(_ item: ShelfItem, at index: Int? = nil) throws {
        let insertionIndex = min(max(index ?? items.count, 0), items.count)
        var updatedItems = items
        updatedItems.insert(item, at: insertionIndex)
        try persistence?.saveNow(updatedItems)
        items = updatedItems
        onItemsDidChange?()
    }

    // MARK: - Removing (never deletes the user's original files)

    /// Removes the given items from the shelf and returns them.
    @discardableResult
    func remove(ids: Set<UUID>) -> [ShelfItem] {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        persist()
        return removed
    }

    @discardableResult
    func removeAndPersistNow(ids: Set<UUID>) throws -> [ShelfItem] {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        let updatedItems = items.filter { !ids.contains($0.id) }
        try persistence?.saveNow(updatedItems)
        items = updatedItems
        selection.subtract(ids)
        onItemsDidChange?()
        return removed
    }

    /// Removes the current selection.
    @discardableResult
    func removeSelection() -> [ShelfItem] {
        remove(ids: selection)
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Reordering

    /// Manual reordering with SwiftUI `onMove` semantics: the elements at
    /// `offsets` are placed at `destination`, interpreted in the pre-move
    /// coordinate space. Out-of-range offsets are ignored.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { items.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { items[$0] }
        for index in validOffsets.reversed() {
            items.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), items.count)
        items.insert(contentsOf: moving, at: insertionIndex)
        persist()
    }

    /// Moves existing top-level items without replacing their identities.
    ///
    /// `destination` uses the same pre-move insertion coordinates as
    /// `move(fromOffsets:toOffset:)`. Returns false when none of the IDs belong
    /// to a current top-level item.
    @discardableResult
    func move(ids: Set<UUID>, toOffset destination: Int) -> Bool {
        let offsets = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard !offsets.isEmpty else { return false }
        move(fromOffsets: offsets, toOffset: destination)
        return true
    }

    // MARK: - Selection

    /// Selects `id`; replaces the selection unless `additive` is true (cmd-click).
    func select(_ id: UUID, additive: Bool = false) {
        guard item(withID: id) != nil else { return }
        if additive {
            selection.insert(id)
        } else {
            selection = [id]
        }
    }

    func toggleSelection(_ id: UUID) {
        guard item(withID: id) != nil else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// Replaces the selection; unknown ids are ignored.
    func setSelection(_ ids: Set<UUID>) {
        selection = ids.intersection(Set(items.map(\.id)))
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    /// Match the visible grid and the panel's Select All keyboard command.
    func selectAllVisible() {
        setSelection(Set(visibleItems.map(\.id)))
    }

    func clearSelection() {
        selection.removeAll()
    }

    func replaceWithPersistedItems(_ restoredItems: [ShelfItem]) {
        removalUndo.removeAll()
        items = restoredItems
        selection.removeAll()
        onItemsDidChange?()
    }

    // MARK: - Stacks

    func canStackSelection(anchoredAt id: UUID) -> Bool {
        guard selection.count >= 2, selection.contains(id) else { return false }
        let members = selectedItems
        return members.count == selection.count && members.allSatisfy { $0.kind != .stack }
    }

    @discardableResult
    func stackSelection(anchoredAt id: UUID) -> UUID? {
        guard canStackSelection(anchoredAt: id) else { return nil }
        return makeStack(from: selection)
    }

    /// Merges the given top-level items into a stack, preserving their current
    /// display order. The stack takes the position of the first selected item
    /// and becomes the only selected item. Returns nil when fewer than two of
    /// the ids exist on the shelf.
    @discardableResult
    func makeStack(from ids: Set<UUID>) -> UUID? {
        let members = items.filter { ids.contains($0.id) }
        guard members.count >= 2,
              let firstIndex = items.firstIndex(where: { ids.contains($0.id) }) else {
            return nil
        }
        let stack = ShelfItem(
            kind: .stack,
            // The UI shows a count badge; naming the stack after its first
            // member keeps the card recognizable.
            displayName: members[0].displayName,
            children: members
        )
        // `firstIndex` is the first selected index, so nothing before it is
        // removed and it stays valid as the insertion position.
        items.removeAll { ids.contains($0.id) }
        items.insert(stack, at: min(firstIndex, items.count))
        selection = [stack.id]
        persist()
        return stack.id
    }

    /// Expands a stack back into its members, inserted at the stack's position
    /// in their original order. The members become the selection. Returns false
    /// when the id does not belong to a non-empty stack.
    @discardableResult
    func unstack(_ stackID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == stackID }),
              items[index].kind == .stack,
              let children = items[index].children,
              !children.isEmpty else {
            return false
        }
        items.remove(at: index)
        items.insert(contentsOf: children, at: min(index, items.count))
        selection = Set(children.map(\.id))
        persist()
        return true
    }

    @discardableResult
    func removeChild(_ childID: UUID, fromStack stackID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == stackID }),
              items[index].kind == .stack,
              let children = items[index].children,
              children.contains(where: { $0.id == childID }) else {
            return false
        }
        let remaining = children.filter { $0.id != childID }
        switch remaining.count {
        case 0:
            items.remove(at: index)
            selection.remove(stackID)
        case 1:
            let survivor = remaining[0]
            items[index] = survivor
            if selection.contains(stackID) {
                selection.remove(stackID)
                selection.insert(survivor.id)
            }
        default:
            items[index].children = remaining
        }
        persist()
        return true
    }

    /// Removes several descendants from one stack in a single persisted
    /// mutation. This keeps keyboard multi-delete deterministic even when the
    /// stack dissolves to one remaining child.
    @discardableResult
    func removeChildren(ids: Set<UUID>, fromStack stackID: UUID) -> Bool {
        guard !ids.isEmpty,
              let index = items.firstIndex(where: { $0.id == stackID }),
              items[index].kind == .stack,
              let children = items[index].children else { return false }
        let remaining = children.filter { !ids.contains($0.id) }
        guard remaining.count != children.count else { return false }
        switch remaining.count {
        case 0:
            items.remove(at: index)
            selection.remove(stackID)
        case 1:
            let survivor = remaining[0]
            items[index] = survivor
            if selection.contains(stackID) {
                selection.remove(stackID)
                selection.insert(survivor.id)
            }
        default:
            items[index].children = remaining
        }
        persist()
        return true
    }

    // MARK: - Item updates

    /// Replaces the item with the same id (e.g. after refreshing a bookmark
    /// that resolved as stale).
    func update(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        persist()
    }

    /// Publishes a top-level runtime-only state change without scheduling a
    /// shelf write. Availability is deliberately absent from shelf.json.
    func updateRuntime(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    /// Atomically replaces a top-level item or stack descendant. The complete
    /// snapshot is written before runtime state changes, so a failed reconnect
    /// can never leave memory pointing at a bookmark that was not saved.
    @discardableResult
    func updateRecursivelyAndPersistNow(_ item: ShelfItem) throws -> Bool {
        var updatedItems = items
        guard Self.replace(item, inside: &updatedItems) else { return false }
        try persistence?.saveNow(updatedItems)
        items = updatedItems
        onItemsDidChange?()
        return true
    }

    /// Sets the runtime-only stale flag. Not persisted — the flag is recomputed
    /// on every launch.
    func markStale(_ id: UUID, _ isStale: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isStale = isStale
    }

    // MARK: - Persistence

    private func persist() {
        persistence?.scheduleSave(items)
        // Every persisted change is an item change (selection isn't persisted and
        // doesn't notify): the one place that drives height and empty-shelf decisions.
        onItemsDidChange?()
    }

    private static func replace(_ replacement: ShelfItem, inside items: inout [ShelfItem]) -> Bool {
        for index in items.indices {
            if items[index].id == replacement.id {
                items[index] = replacement
                return true
            }
            if var children = items[index].children,
               replace(replacement, inside: &children) {
                items[index].children = children
                return true
            }
        }
        return false
    }
}
