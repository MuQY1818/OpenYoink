import AppKit
import Observation

enum FavoriteFolderDropTarget: Equatable { case folder(UUID), addFavorite }
enum FavoriteFolderDropLocator {
    static func target(at point: CGPoint, tiles: [UUID: CGRect], viewport: CGRect,
                       addFrame: CGRect) -> FavoriteFolderDropTarget? {
        if !addFrame.isEmpty && addFrame.contains(point) { return .addFavorite }
        guard viewport.contains(point) else { return nil }
        return tiles.first { $0.value.intersection(viewport).contains(point) }.map { .folder($0.key) }
    }
}

@MainActor
@Observable
final class FavoriteFolderDropCoordinator {
    private(set) var target: FavoriteFolderDropTarget?
    private(set) var isCopying = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var message: String?
    private(set) var conflictName: String?
    @ObservationIgnored var tileFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var viewport: CGRect = .zero
    @ObservationIgnored var addFrame: CGRect = .zero
    @ObservationIgnored private let folders: FavoriteFoldersStore
    @ObservationIgnored private let bookmarks: BookmarkService
    @ObservationIgnored private let copier: FavoriteFolderCopyService
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<FolderCopyConflictDecision, Never>?
    @ObservationIgnored var onActivity: (@MainActor (IslandActivity?) -> Void)?
    @ObservationIgnored private(set) var protectedPaths: Set<String> = []

    init(folders: FavoriteFoldersStore, bookmarks: BookmarkService) {
        self.folders = folders
        self.bookmarks = bookmarks
        copier = FavoriteFolderCopyService(bookmarks: bookmarks)
    }
    func update(_ context: DragContainerDropContext) -> Bool {
        target = nil
        guard !isCopying else { return false }
        let hit = FavoriteFolderDropLocator.target(at: context.location, tiles: tileFrames,
                                                  viewport: viewport, addFrame: addFrame)
        switch hit {
        case .folder(let id):
            guard !folders.isUnavailable(id), folders.items.contains(where: { $0.id == id }),
                  Self.hasFiles(context) else { return false }
        case .addFavorite:
            guard !context.isInternal, folders.canImportFolders(from: context.pasteboard) else { return false }
        case nil: return false
        }
        target = hit
        return true
    }
    func perform(_ context: DragContainerDropContext) -> Bool {
        guard update(context), let target else { return false }
        defer { resetTarget() }
        if target == .addFavorite { return folders.importFolders(from: context.pasteboard) }
        guard case .folder(let id) = target, let destination = folders.copyDestinationBookmark(for: id) else { return false }
        let sources = fileBookmarks(context)
        guard !sources.isEmpty else { return false }
        isCopying = true
        completed = 0
        total = sources.count
        message = nil
        protectedPaths = Set(sources.compactMap { try? bookmarks.resolve($0).url.path })
        onActivity?(.init(id: "folders.copy", moduleID: .folders, priority: .transfer,
                          title: String(localized: "Copying files…"), detail: nil,
                          systemImage: "doc.on.doc", expiresAt: nil))
        copyTask = Task { [self] in
            let result = await copier.copy(sources, to: destination, conflict: { [weak self] name in
                await self?.resolveConflict(name) ?? .cancel
            }, progress: { [weak self] done, count in await self?.updateProgress(done, total: count) })
            isCopying = false
            protectedPaths = []
            copyTask = nil
            message = String(localized: "Copied: \(result.copied) · Skipped: \(result.skipped) · Failed: \(result.failed) · Cancelled: \(result.cancelled)")
            onActivity?(.init(id: "folders.copy", moduleID: .folders, priority: .transfer,
                              title: String(localized: "Folder copy complete"), detail: message,
                              systemImage: result.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                              expiresAt: Date().addingTimeInterval(8)))
        }
        return true
    }
    private func fileBookmarks(_ context: DragContainerDropContext) -> [Data] {
        if let items = context.internalItems {
            let leaves = DragPayloadBuilder.flattenedItems(items)
            guard !leaves.isEmpty, leaves.allSatisfy({ [.file, .folder, .image].contains($0.kind)
                && $0.availability == .available && $0.bookmark != nil }) else { return [] }
            return leaves.compactMap(\.bookmark)
        }
        if context.isInternal { return [] }
        let urls = (context.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { ($0 as? NSURL).map { $0 as URL } }
        let data = urls.compactMap { try? bookmarks.createBookmark(for: $0) }
        return data.count == urls.count ? data : []
    }
    static func hasFiles(_ context: DragContainerDropContext) -> Bool {
        if let items = context.internalItems {
            let leaves = DragPayloadBuilder.flattenedItems(items)
            return !leaves.isEmpty && leaves.allSatisfy {
                [.file, .folder, .image].contains($0.kind) && $0.availability == .available && $0.bookmark != nil
            }
        }
        return !context.isInternal && !(context.pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) ?? []).isEmpty
    }
    private func updateProgress(_ done: Int, total: Int) { completed = done; self.total = total }
    private func resolveConflict(_ name: String) async -> FolderCopyConflictDecision {
        guard !Task.isCancelled else { return .cancel }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflictName = name
        }
    }
    func decideConflict(_ decision: FolderCopyConflictDecision) {
        conflictName = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: decision)
    }
    func cancelCopy() { copyTask?.cancel(); decideConflict(.cancel) }
    func resetTarget() { target = nil }
}
