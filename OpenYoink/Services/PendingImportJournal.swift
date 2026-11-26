import Foundation

/// Crash-recovery journal for files delivered through `NSFilePromiseReceiver`.
///
/// A promised file exists only after the source application has finished
/// writing it into a staging directory. Before moving that file to its final
/// managed URL, OpenYoink records both locations here. The record is removed
/// only after the resulting ShelfItem has been synchronously written to
/// `shelf.json`, which makes every crash window retryable.
final class PendingImportJournal: Sendable {

    struct Record: Codable, Equatable, Identifiable, Sendable {
        /// Stable transaction id; also used as the eventual ShelfItem id so a
        /// crash after shelf persistence but before journal removal is easy to
        /// reconcile without creating a duplicate card.
        var id: UUID
        var stagingPath: String
        var destinationPath: String
        var displayName: String
        var promisedTypeIdentifiers: [String]
        var createdAt: Date
    }

    enum JournalError: LocalizedError, Equatable {
        case damaged
        case pathOutsideManagedDirectory
        case missingRecord(UUID)

        var errorDescription: String? {
            switch self {
            case .damaged:
                String(localized: "Pending import recovery data is damaged.")
            case .pathOutsideManagedDirectory:
                String(localized: "The pending import points outside OpenYoink's managed storage.")
            case .missingRecord:
                String(localized: "The pending import recovery record is missing.")
            }
        }
    }

    let directoryURL: URL
    let managedDirectoryURL: URL
    private let journal: RecoveryJournal<Record>

    init(directoryURL: URL? = nil, managedDirectoryURL: URL? = nil) {
        let support = directoryURL ?? AppPaths.applicationSupport()
        let managed = managedDirectoryURL ?? AppPaths.materialized(in: support)
        self.directoryURL = support
        self.managedDirectoryURL = managed
        // Records naming paths outside managed storage are treated as damage:
        // recovery would otherwise move or delete arbitrary files.
        self.journal = RecoveryJournal(
            fileURL: support.appendingPathComponent("pending-imports.json"),
            logCategory: "PendingImportJournal",
            damagedError: { JournalError.damaged },
            isValid: { record in
                URL(fileURLWithPath: record.stagingPath).isContained(in: managed)
                    && URL(fileURLWithPath: record.destinationPath).isContained(in: managed)
            }
        )
    }

    func loadResult() -> LoadResult<[Record]> {
        journal.load()
    }

    /// Creates the durable boundary before the staging payload is moved.
    @discardableResult
    func create(stagingURL: URL,
                destinationURL: URL,
                displayName: String,
                promisedTypeIdentifiers: [String]) throws -> Record {
        guard isManagedPath(stagingURL), isManagedPath(destinationURL) else {
            throw JournalError.pathOutsideManagedDirectory
        }
        let record = Record(
            id: UUID(),
            stagingPath: stagingURL.standardizedFileURL.path,
            destinationPath: destinationURL.standardizedFileURL.path,
            displayName: displayName,
            promisedTypeIdentifiers: promisedTypeIdentifiers,
            createdAt: Date()
        )
        try journal.mutate { $0.append(record) }
        return record
    }

    /// Changes the reserved destination before a retrying move. The journal is
    /// updated first, so a crash during the following move still names both
    /// possible locations.
    func updateDestination(id: UUID, to destinationURL: URL) throws -> Record {
        guard isManagedPath(destinationURL) else {
            throw JournalError.pathOutsideManagedDirectory
        }
        return try journal.mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw JournalError.missingRecord(id)
            }
            records[index].destinationPath = destinationURL.standardizedFileURL.path
            return records[index]
        }
    }

    func remove(id: UUID) throws {
        try journal.remove(id: id)
    }

    /// Both candidates must survive cleanup: a crash can leave the payload at
    /// either path, and a cross-volume move can briefly leave both.
    func protectedPaths() -> Set<String> {
        Set(loadResult().contents.flatMap { [$0.stagingPath, $0.destinationPath] })
    }

    var permitsOrphanCleanup: Bool { loadResult().isTrusted }

    private func isManagedPath(_ url: URL) -> Bool {
        url.isContained(in: managedDirectoryURL)
    }
}
