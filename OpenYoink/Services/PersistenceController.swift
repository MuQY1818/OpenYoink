import Foundation
import OSLog

/// On-disk envelope for `shelf.json`.
private struct ShelfSnapshot: Codable, Sendable {
    var schemaVersion: Int
    var items: [ShelfItem]
}

/// JSON persistence for the shelf's items.
///
/// Storage is a single `shelf.json` in `Application Support/OpenYoink`. Writes
/// are atomic and debounced; each write keeps the previous decodable version
/// as `shelf.json.backup`, and an unreadable file is quarantined as
/// `shelf.json.corrupt-<timestamp>`. Both are offered in Settings > Storage.
@MainActor
final class PersistenceController {
    typealias LoadResult = OpenYoink.LoadResult<[ShelfItem]>

    /// Current on-disk schema version. Bump it and add a migration in
    /// `migrate(_:)` when the format changes.
    static let currentSchemaVersion = 1

    /// Directory containing `shelf.json`; inject a custom one in tests.
    let directoryURL: URL

    /// Number of completed disk writes (diagnostics and tests).
    private(set) var saveCount = 0

    // Older releases treat removal archives as quarantined data and protect their files.
    private static let removalSnapshotPrefix = "shelf.json.corrupt-removed-"

    private let file: JSONFileStore<ShelfSnapshot>
    private let logger = Log.make(category: "Persistence")
    private let debounceInterval: Duration
    private lazy var writer = DebouncedWriter<[ShelfItem]>(interval: debounceInterval) { [weak self] items in
        self?.writeOrLog(items)
    }

    init(directoryURL: URL? = nil, debounceInterval: Duration = .milliseconds(500)) {
        self.directoryURL = directoryURL ?? AppPaths.applicationSupport()
        self.file = JSONFileStore(self.directoryURL.appendingPathComponent("shelf.json"), dateStyle: .iso8601)
        self.debounceInterval = debounceInterval
    }

    // MARK: - Loading

    /// Reads `shelf.json`. A damaged file is quarantined and reported as
    /// `.failed`; callers must keep that result rather than reading again,
    /// which would then see `.missing`.
    func loadResult() -> LoadResult {
        switch file.load(logger: logger) {
        case .loaded(let snapshot):
            return .loaded(migrate(snapshot).items)
        case .missing:
            return .missing
        case .failed:
            file.quarantine(logger: logger)
            return .failed
        }
    }

    /// Final safety gate for deleting unreferenced materialized files: this
    /// launch's read must be trusted *and* no quarantined snapshot may remain.
    /// The latter persists across launches — after quarantine the next read
    /// is `.missing`, which alone would permit deleting recovery material.
    func canSafelyCleanupMaterializedOrphans(after result: LoadResult) -> Bool {
        guard result.isTrusted else { return false }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return true }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
            for name in names {
                if Self.isRemovalSnapshotName(name) {
                    // A damaged removal archive can still own the only retained
                    // managed copy. Never infer that its files are unreferenced.
                    guard (try? decodeSnapshot(at: directoryURL.appendingPathComponent(name))) != nil else {
                        return false
                    }
                    continue
                }
                if name.hasPrefix(file.quarantinePrefix) { return false }
            }
            return true
        } catch {
            logger.error("Cannot inspect persistence directory before orphan cleanup: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Recovery snapshots

    struct RecoverySnapshot: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case lastKnownGood
            case quarantined
            case removedItems
        }

        let url: URL
        let kind: Kind
        let modifiedAt: Date?
        let byteCount: Int64
        /// Undecodable quarantined files are listed for manual repair but can
        /// never overwrite current data.
        let isRecoverable: Bool

        var id: URL { url }
    }

    enum RecoveryError: LocalizedError, Equatable {
        case invalidSnapshot
        case snapshotIsUnreadable

        var errorDescription: String? {
            switch self {
            case .invalidSnapshot:
                String(localized: "The selected recovery file is not managed by OpenYoink.")
            case .snapshotIsUnreadable:
                String(localized: "This recovery file is damaged and cannot be restored automatically.")
            }
        }
    }

    /// Retains the complete shelf before a batch removal, independently of the
    /// rotating last-known-good backup. Archives are deleted only by an explicit
    /// recovery-data action, so removed managed copies remain protected on launch.
    func saveRemovalRecoverySnapshot(_ items: [ShelfItem]) throws {
        let snapshot = ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items)
        let url = directoryURL.appendingPathComponent(
            Self.removalSnapshotPrefix + UUID().uuidString + ".json"
        )
        try JSONFileStore<ShelfSnapshot>(url, dateStyle: .iso8601).writeAtomically(snapshot)
    }

    /// Lists independent removal archives, the last known good shelf and
    /// quarantined data. Only fully decodable snapshots are restorable.
    func recoverySnapshots() -> [RecoverySnapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard let kind = recoveryKind(of: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return RecoverySnapshot(
                url: url,
                kind: kind,
                modifiedAt: values?.contentModificationDate,
                byteCount: Int64(values?.fileSize ?? 0),
                isRecoverable: (try? decodeSnapshot(at: url)) != nil
            )
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func loadRecoverySnapshot(_ snapshot: RecoverySnapshot) throws -> [ShelfItem] {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        do {
            return try decodeSnapshot(at: snapshot.url).items
        } catch {
            throw RecoveryError.snapshotIsUnreadable
        }
    }

    func discardRecoverySnapshot(_ snapshot: RecoverySnapshot) throws {
        guard isManagedRecoveryURL(snapshot.url) else { throw RecoveryError.invalidSnapshot }
        guard FileManager.default.fileExists(atPath: snapshot.url.path) else { return }
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// Items in every decodable recovery snapshot; their files must survive
    /// orphan cleanup so a restore brings back content, not just cards.
    func recoverableSnapshotItems() -> [ShelfItem] {
        recoverySnapshots().flatMap { snapshot in
            (try? loadRecoverySnapshot(snapshot)) ?? []
        }
    }

    private func recoveryKind(of url: URL) -> RecoverySnapshot.Kind? {
        let name = url.lastPathComponent
        if name == file.backupURL.lastPathComponent { return .lastKnownGood }
        if Self.isRemovalSnapshotName(name) { return .removedItems }
        if name.hasPrefix(file.quarantinePrefix) { return .quarantined }
        return nil
    }

    private func isManagedRecoveryURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent() == directoryURL.standardizedFileURL
            && recoveryKind(of: standardized) != nil
    }

    private static func isRemovalSnapshotName(_ name: String) -> Bool {
        name.hasPrefix(removalSnapshotPrefix) && name.hasSuffix(".json")
    }

    private func decodeSnapshot(at url: URL) throws -> ShelfSnapshot {
        migrate(try file.decode(contentsOf: url))
    }

    // MARK: - Saving

    /// Schedules a debounced write; rapid calls coalesce into one write of the
    /// latest value.
    func scheduleSave(_ items: [ShelfItem]) {
        writer.schedule(items)
    }

    /// Writes immediately, discarding any pending debounced save.
    func saveNow(_ items: [ShelfItem]) throws {
        writer.cancel()
        try write(items)
    }

    /// Runs any pending debounced save now.
    func flushPendingSave() {
        writer.flush()
    }

    private func writeOrLog(_ items: [ShelfItem]) {
        do {
            try write(items)
        } catch {
            logger.error("Failed to save shelf.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ items: [ShelfItem]) throws {
        try file.write(ShelfSnapshot(schemaVersion: Self.currentSchemaVersion, items: items),
                       keepingBackup: true,
                       logger: logger)
        saveCount += 1
    }

    /// Schema migration hook. Files from a newer app version are decoded
    /// best-effort (unknown fields are ignored).
    private func migrate(_ snapshot: ShelfSnapshot) -> ShelfSnapshot {
        if snapshot.schemaVersion > Self.currentSchemaVersion {
            logger.warning("shelf.json schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion); decoding best-effort")
        }
        return snapshot
    }
}
