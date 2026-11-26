import Foundation

/// Crash-recovery journal for managed moves (`Command`-drop).
///
/// A managed move becomes destructive only after the original file is sent to
/// the Trash.  Before that step, `CutMoveService` writes a `.prepared` record
/// containing both the ordinary reference item and the managed-copy item.  If
/// the process exits before the shelf snapshot is committed, the next launch
/// can reconstruct a safe shelf item instead of treating the managed copy as
/// an orphan.
///
/// The journal lives beside `shelf.json` in its own file. Access is serialized
/// because managed copies are prepared on a background task while startup and
/// storage recovery run on the main actor.
final class ManagedMoveJournal: Sendable {

    struct Record: Codable, Equatable, Identifiable, Sendable {
        enum State: String, Codable, Equatable, Sendable {
            /// The managed copy exists and the original has not intentionally
            /// been moved yet.
            case prepared
            /// The original was moved to the Trash; the shelf snapshot may not
            /// contain `managedItem` yet.
            case originalTrashed
        }

        /// The managed item's id is also the transaction id.  This makes
        /// reconciliation with an already-persisted ShelfItem deterministic.
        var id: UUID { managedItem.id }

        var state: State
        var referenceItem: ShelfItem
        var managedItem: ShelfItem
        var resultingTrashPath: String?
        var createdAt: Date
    }

    enum JournalError: LocalizedError, Equatable {
        case damaged
        case missingRecord(UUID)

        var errorDescription: String? {
            switch self {
            case .damaged:
                String(localized: "Managed move recovery data is damaged.")
            case .missingRecord:
                String(localized: "The managed move recovery record is missing.")
            }
        }
    }

    let directoryURL: URL
    private let journal: RecoveryJournal<Record>

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppPaths.applicationSupport()
        self.journal = RecoveryJournal(
            fileURL: self.directoryURL.appendingPathComponent("managed-moves.json"),
            logCategory: "ManagedMoveJournal",
            damagedError: { JournalError.damaged }
        )
    }

    func loadResult() -> LoadResult<[Record]> {
        journal.load()
    }

    /// Writes the safety boundary that must exist before the original can be
    /// moved to the Trash.
    func createPrepared(referenceItem: ShelfItem, managedItem: ShelfItem) throws {
        try journal.mutate { records in
            records.removeAll { $0.id == managedItem.id }
            records.append(Record(
                state: .prepared,
                referenceItem: referenceItem,
                managedItem: managedItem,
                resultingTrashPath: nil,
                createdAt: Date()
            ))
        }
    }

    /// Marks the destructive step as completed. A failure to persist this
    /// transition is still recoverable: the durable `.prepared` record plus a
    /// missing source and existing managed copy is treated conservatively on
    /// the next launch.
    func markOriginalTrashed(id: UUID, resultingURL: URL?) throws {
        try journal.mutate { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else {
                throw JournalError.missingRecord(id)
            }
            records[index].state = .originalTrashed
            records[index].resultingTrashPath = resultingURL?.path
        }
    }

    /// Removes a transaction only after its ShelfItem has been synchronously
    /// persisted, or after startup recovery has safely resolved it.
    func remove(id: UUID) throws {
        try journal.remove(id: id)
    }

    /// Paths that must survive automatic and user-triggered orphan cleanup.
    func protectedPaths() -> Set<String> {
        Set(loadResult().contents.compactMap(\.managedItem.path))
    }

    var permitsOrphanCleanup: Bool {
        loadResult().isTrusted
    }
}

/// Pure decision table used by launch recovery. Keeping filesystem inspection
/// outside the planner makes every crash window explicit and unit-testable.
enum ManagedMoveRecoveryPlanner {
    enum Decision: Equatable, Sendable {
        /// The shelf snapshot already contains one side of the transaction.
        case alreadyCommitted
        /// No managed copy survives, but the source is still reachable.
        case recoverReference
        /// The source can no longer be relied on; restore the durable copy.
        case recoverManaged
        /// Neither source nor managed copy exists. Preserve the journal and
        /// block cleanup so a future/manual recovery remains possible.
        case unresolved
    }

    static func decision(for record: ManagedMoveJournal.Record,
                         sourceExists: Bool,
                         managedExists: Bool,
                         persistedItemIDs: Set<UUID>) -> Decision {
        if persistedItemIDs.contains(record.managedItem.id)
            || persistedItemIDs.contains(record.referenceItem.id) {
            return .alreadyCommitted
        }
        // Once `.prepared` is durable, the copy already contains the user's
        // data. Even if the source path currently exists, it might be a new
        // file created after a crash in the trash-before-state-update window.
        // Prefer the managed copy: a harmless duplicate is safer than deleting
        // the only surviving copy of the original content.
        if managedExists {
            return .recoverManaged
        }
        if sourceExists {
            return .recoverReference
        }
        return .unresolved
    }
}
