import Foundation

/// Recursive queries over shelf items, where stacks embed their members in
/// `children`.
extension Sequence where Element == ShelfItem {
    /// Stacks replaced by their members (recursively), order preserved. Empty
    /// stacks are kept as-is. Dragging a stack card drags all of its members.
    var flattened: [ShelfItem] {
        flatMap { item -> [ShelfItem] in
            guard item.kind == .stack, let children = item.children, !children.isEmpty else {
                return [item]
            }
            return children.flattened
        }
    }

    /// Finds an item at any depth.
    func item(withID id: UUID) -> ShelfItem? {
        for item in self {
            if item.id == id { return item }
            if let match = item.children?.item(withID: id) { return match }
        }
        return nil
    }

    func contains(id: UUID) -> Bool {
        item(withID: id) != nil
    }

    /// Ids of all items at any depth.
    var ids: Set<UUID> {
        reduce(into: Set<UUID>()) { ids, item in
            ids.insert(item.id)
            ids.formUnion(item.children?.ids ?? [])
        }
    }

    /// Standardized paths of items (at any depth) whose files live inside
    /// `directory`.
    func materializedPaths(in directory: URL) -> Set<String> {
        reduce(into: Set<String>()) { paths, item in
            if let url = item.fileURL, url.isContained(in: directory, resolvingSymlinks: false) {
                paths.insert(url.standardizedFileURL.path)
            }
            paths.formUnion(item.children?.materializedPaths(in: directory) ?? [])
        }
    }
}
