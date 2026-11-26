import Foundation

@MainActor
enum MaterializedFileGuard {
    static func protectedPaths(
        for items: [ShelfItem], persistence: PersistenceController, tempFiles: TempFileService,
        managedMoves: ManagedMoveJournal?, pendingImports: PendingImportJournal?,
        additional: Set<String> = []
    ) -> Set<String> {
        (items + persistence.recoverableSnapshotItems())
            .materializedPaths(in: tempFiles.directoryURL)
            .union(managedMoves?.protectedPaths() ?? [])
            .union(pendingImports?.protectedPaths() ?? [])
            .union(additional)
    }
}
