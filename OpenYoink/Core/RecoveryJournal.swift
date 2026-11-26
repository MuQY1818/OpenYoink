import Foundation
import OSLog

/// A thread-safe, crash-safe list of in-flight transactions.
///
/// Records are written before a risky file operation and removed once its
/// result is durable, so every crash window can be reconciled on the next
/// launch. A damaged or newer-schema file loads as `.failed`; mutations then
/// throw `damagedError` instead of overwriting data that might still matter.
/// An empty journal is deleted from disk.
final class RecoveryJournal<Record: Codable & Sendable & Identifiable>: @unchecked Sendable
where Record.ID == UUID {
    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var records: [Record]
    }

    static var currentSchemaVersion: Int { 1 }

    private let file: JSONFileStore<Snapshot>
    private let isValid: @Sendable (Record) -> Bool
    private let damagedError: @Sendable () -> any Error
    private let logger: Logger
    private let lock = NSLock()

    init(fileURL: URL,
         logCategory: String,
         damagedError: @escaping @Sendable () -> any Error,
         isValid: @escaping @Sendable (Record) -> Bool = { _ in true }) {
        self.file = JSONFileStore(fileURL)
        self.logger = Log.make(category: logCategory)
        self.damagedError = damagedError
        self.isValid = isValid
    }

    func load() -> LoadResult<[Record]> {
        lock.withLock { loadLocked() }
    }

    /// Applies `body` to the current records and persists the result.
    @discardableResult
    func mutate<T>(_ body: (inout [Record]) throws -> T) throws -> T {
        try lock.withLock {
            var records = try recordsForMutationLocked()
            let result = try body(&records)
            try writeLocked(records)
            return result
        }
    }

    /// Removes a record; a no-op (without rewriting the file) if it is absent.
    func remove(id: UUID) throws {
        try lock.withLock {
            var records = try recordsForMutationLocked()
            guard records.contains(where: { $0.id == id }) else { return }
            records.removeAll { $0.id == id }
            try writeLocked(records)
        }
    }

    private func recordsForMutationLocked() throws -> [Record] {
        switch loadLocked() {
        case .loaded(let records): records
        case .missing: []
        case .failed: throw damagedError()
        }
    }

    private func writeLocked(_ records: [Record]) throws {
        if records.isEmpty {
            try file.delete()
        } else {
            try file.write(Snapshot(schemaVersion: Self.currentSchemaVersion, records: records),
                           keepingBackup: true,
                           logger: logger)
        }
    }

    private func loadLocked() -> LoadResult<[Record]> {
        switch file.load(logger: logger) {
        case .missing:
            return .missing
        case .failed:
            return .failed
        case .loaded(let snapshot):
            guard snapshot.schemaVersion <= Self.currentSchemaVersion else {
                logger.warning("\(self.file.url.lastPathComponent, privacy: .public) schema v\(snapshot.schemaVersion) is newer than supported")
                return .failed
            }
            guard snapshot.records.allSatisfy(isValid) else { return .failed }
            return .loaded(snapshot.records)
        }
    }
}
