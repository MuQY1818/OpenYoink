import AppKit
import OSLog

@MainActor
final class LaunchMaintenance {
    private let logger = Log.make(category: "App")
    private let shelfStore: ShelfStore
    private let persistence: PersistenceController
    private let initialShelfLoadResult: PersistenceController.LoadResult
    private let managedMoveJournal: ManagedMoveJournal
    private let pendingImportJournal: PendingImportJournal
    private let tempFileService: TempFileService
    private let bookmarkService: BookmarkService
    private let shelfNotice: ShelfNoticeModel

    init(shelfStore: ShelfStore,
         persistence: PersistenceController,
         initialShelfLoadResult: PersistenceController.LoadResult,
         managedMoveJournal: ManagedMoveJournal,
         pendingImportJournal: PendingImportJournal,
         tempFileService: TempFileService,
         bookmarkService: BookmarkService,
         shelfNotice: ShelfNoticeModel) {
        self.shelfStore = shelfStore
        self.persistence = persistence
        self.initialShelfLoadResult = initialShelfLoadResult
        self.managedMoveJournal = managedMoveJournal
        self.pendingImportJournal = pendingImportJournal
        self.tempFileService = tempFileService
        self.bookmarkService = bookmarkService
        self.shelfNotice = shelfNotice
    }

    func run() {
        recoverManagedMoveTransactions()
        reconcilePendingImports()
        resolvePersistedBookmarks()
        if !persistence.canSafelyCleanupMaterializedOrphans(after: initialShelfLoadResult)
            || !managedMoveJournal.permitsOrphanCleanup
            || !pendingImportJournal.permitsOrphanCleanup {
            logger.warning("Skipping materialized orphan cleanup because shelf recovery data is present or persistence could not be trusted")
        } else {
            cleanupMaterializedOrphans()
        }
        tempFileService.cleanupStaleStagingDirectories(
            keepingPaths: pendingImportJournal.protectedPaths()
        )
    }

    func finish() {
        do {
            try persistence.saveNow(shelfStore.items)
            reconcileCommittedManagedMoves()
            reconcilePendingImports()
        } catch {
            // Keep recovery transactions when durability cannot be proven.
            logger.error("Failed to synchronously save shelf during termination: \(error.localizedDescription, privacy: .public)")
        }
        bookmarkService.stopAccessingAll()
    }

    func legacyInstallEvidence() -> Bool {
        switch initialShelfLoadResult {
        case .loaded, .failed:
            return true
        case .missing:
            break
        }

        if let names = try? FileManager.default.contentsOfDirectory(
            atPath: persistence.directoryURL.path
        ), names.contains(where: { $0 != "Tutorial" }) {
            return true
        }

        let domainName = Bundle.main.bundleIdentifier ?? "com.weijue.OpenYoink"
        let persistent = UserDefaults.standard.persistentDomain(forName: domainName) ?? [:]
        return persistent.keys.contains { key in
            key != "OpenYoink.onboardingVersion"
        }
    }

    // MARK: - Bookmark resolution at launch

    private func resolvePersistedBookmarks() {
        for item in shelfStore.items {
            if let refreshed = refreshedByResolvingBookmark(item) {
                shelfStore.update(refreshed)
            }
        }
    }

    func refreshedByResolvingBookmark(_ item: ShelfItem) -> ShelfItem? {
        let result = ItemAvailabilityResolver.refresh(
            item,
            bookmarkService: bookmarkService
        )
        return result.item == item ? nil : result.item
    }

    // MARK: - Materialized file cleanup

    /// Reconciles crash-recovery transactions before any materialized cleanup.
    /// Any surviving managed copy is restored as the authoritative `isCut`
    /// item. The source path may have been recreated after a crash, so its mere
    /// existence cannot prove that trashing never happened. Only when the
    /// managed copy is gone do we fall back to the source reference. Nothing is
    /// mutated while shelf persistence is untrusted.
    private func recoverManagedMoveTransactions() {
        let loadResult = managedMoveJournal.loadResult()
        guard case .loaded(let records) = loadResult, !records.isEmpty else {
            if loadResult == .failed {
                shelfNotice.show(String(localized: "Managed move recovery data needs attention. Automatic cleanup is disabled."))
            }
            return
        }

        var recoveredItems = shelfStore.items
        var resolved: [ManagedMoveJournal.Record] = []
        var unresolvedCount = 0
        let fileManager = FileManager.default
        let persistenceIsTrusted = persistence.canSafelyCleanupMaterializedOrphans(
            after: initialShelfLoadResult
        )
        let persistedItemIDs = shelfStore.items.ids

        for record in records {
            let sourceExists = record.referenceItem.path.map(fileManager.fileExists(atPath:)) ?? false
            let managedExists = record.managedItem.path.map(fileManager.fileExists(atPath:)) ?? false
            let decision = ManagedMoveRecoveryPlanner.decision(
                for: record,
                sourceExists: sourceExists,
                managedExists: managedExists,
                persistedItemIDs: persistedItemIDs
            )

            if decision == .alreadyCommitted {
                // A crash after shelf save but before journal deletion needs no
                // content mutation.
                try? managedMoveJournal.remove(id: record.id)
                continue
            }
            guard persistenceIsTrusted else {
                logger.warning("Deferring managed move recovery because shelf persistence is not trusted")
                unresolvedCount += 1
                continue
            }

            let itemToRecover: ShelfItem
            switch decision {
            case .recoverReference:
                itemToRecover = record.referenceItem
            case .recoverManaged:
                itemToRecover = record.managedItem
            case .alreadyCommitted:
                continue
            case .unresolved:
                unresolvedCount += 1
                continue
            }
            if !recoveredItems.contains(id: itemToRecover.id) {
                recoveredItems.append(itemToRecover)
            }
            resolved.append(record)
        }

        if !resolved.isEmpty {
            do {
                try persistence.saveNow(recoveredItems)
                shelfStore.replaceWithPersistedItems(recoveredItems)
                for record in resolved {
                    try? managedMoveJournal.remove(id: record.id)
                }
                shelfNotice.show(String(localized: "Recovered an interrupted managed move."))
            } catch {
                logger.error("Failed to persist recovered managed moves: \(error.localizedDescription, privacy: .public)")
                unresolvedCount += resolved.count
            }
        }

        if unresolvedCount > 0 {
            shelfNotice.show(String(localized: "Some managed move recovery data needs attention. Automatic cleanup is disabled."))
        }
    }

    /// Normal termination flushes shelf.json first, then clears any journal
    /// records whose managed/reference item is now durable. Crashes leave the
    /// records intact for `recoverManagedMoveTransactions`.
    private func reconcileCommittedManagedMoves() {
        guard case .loaded(let records) = managedMoveJournal.loadResult() else { return }
        for record in records where shelfContainsItem(id: record.managedItem.id)
            || shelfContainsItem(id: record.referenceItem.id) {
            try? managedMoveJournal.remove(id: record.id)
        }
    }

    /// Removes only records whose stable id is already present in the loaded
    /// shelf. All other records remain available in Settings > Storage for an
    /// explicit retry; startup never guesses that an incomplete import should
    /// silently create a card.
    private func reconcilePendingImports() {
        switch pendingImportJournal.loadResult() {
        case .loaded(let records):
            var remainingCount = 0
            for record in records {
                if shelfContainsItem(id: record.id) {
                    do {
                        try pendingImportJournal.remove(id: record.id)
                    } catch {
                        logger.error("Failed to reconcile completed pending import \(record.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                } else {
                    remainingCount += 1
                }
            }
            if remainingCount > 0 {
                shelfNotice.show(String(localized: "A received file was kept safely. Open Recovery to finish importing it."))
            }
        case .failed:
            shelfNotice.show(String(localized: "Pending import recovery data needs attention. Automatic cleanup is disabled."))
        case .missing:
            break
        }
    }

    private func shelfContainsItem(id: UUID) -> Bool {
        shelfStore.items.contains(id: id)
    }

    private func cleanupMaterializedOrphans() {

        let paths = MaterializedFileGuard.protectedPaths(
            for: shelfStore.items, persistence: persistence, tempFiles: tempFileService,
            managedMoves: managedMoveJournal, pendingImports: pendingImportJournal
        )
        tempFileService.cleanupOrphans(keepingPaths: paths)
    }
}
