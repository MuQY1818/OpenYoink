import Foundation
import OSLog

/// Summary of one dragged-out item.
struct RecentEntry: Codable, Equatable, Identifiable, Sendable {
    /// Unique per record: the same item can be dragged out repeatedly.
    var id: UUID
    var displayName: String
    var kind: ItemKind
    /// Last known path of file-backed items, used to re-add from the menu.
    var path: String?
    var urlString: String?
    /// First 100 characters of text items.
    var textPreview: String?
    var draggedOutAt: Date

    init(item: ShelfItem, draggedOutAt: Date, id: UUID = UUID()) {
        self.id = id
        self.displayName = item.displayName
        self.kind = item.kind
        self.path = item.path
        self.urlString = item.urlString
        self.textPreview = item.text.map { String($0.prefix(100)) }
        self.draggedOutAt = draggedOutAt
    }
}

/// The last `maxEntryCount` dragged-out items, newest first, persisted to
/// `recents.json`. Drag-outs are rare, so writes are immediate rather than
/// debounced. A damaged file falls back to an empty history.
@MainActor
@Observable
final class RecentItemsService {
    static let maxEntryCount = 20
    private static let currentSchemaVersion = 1

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var entries: [RecentEntry]
    }

    /// Current history, newest first.
    private(set) var entries: [RecentEntry] = []

    /// Storage directory; inject a temporary one in tests.
    let directoryURL: URL

    private let file: JSONFileStore<Snapshot>
    private let logger = Log.make(category: "RecentItems")

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppPaths.applicationSupport()
        self.file = JSONFileStore(self.directoryURL.appendingPathComponent("recents.json"), dateStyle: .iso8601)
        if let snapshot = file.load(logger: logger).value {
            if snapshot.schemaVersion > Self.currentSchemaVersion {
                logger.warning("recents.json schema v\(snapshot.schemaVersion) is newer than supported; decoding best-effort")
            }
            entries = snapshot.entries
        }
    }

    /// Records one drag-out batch at the front (keeping drag order inside the
    /// batch), trims to the limit and saves.
    func record(_ items: [ShelfItem], at date: Date = Date()) {
        guard !items.isEmpty else { return }
        entries.insert(contentsOf: items.map { RecentEntry(item: $0, draggedOutAt: date) }, at: 0)
        if entries.count > Self.maxEntryCount {
            entries.removeLast(entries.count - Self.maxEntryCount)
        }
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    private func save() {
        do {
            try file.write(Snapshot(schemaVersion: Self.currentSchemaVersion, entries: entries),
                           keepingBackup: false,
                           logger: logger)
        } catch {
            logger.error("Failed to save recents.json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
