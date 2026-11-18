import Foundation
import Observation

struct RecentDownload: Identifiable, Equatable, Sendable {
    let url: URL
    let date: Date
    var id: URL { url }
}

enum RecentDownloadsScanner {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
        .addedToDirectoryDateKey, .contentModificationDateKey,
    ]
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    static func entry(at url: URL) -> RecentDownload? {
        guard !url.lastPathComponent.hasPrefix("."),
              !partialExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.isHidden != true else { return nil }
        return RecentDownload(url: url, date: values.addedToDirectoryDate ?? values.contentModificationDate ?? .distantPast)
    }

    static func scan(_ folder: URL, limit: Int = 15) throws -> [RecentDownload] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var newest: [RecentDownload] = []
        guard limit > 0 else { return newest }
        for url in urls {
            try Task.checkCancellation()
            guard let item = entry(at: url) else { continue }
            let index = newest.firstIndex {
                item.date > $0.date || (item.date == $0.date && item.url.path < $0.url.path)
            } ?? newest.endIndex
            guard index < limit else { continue }
            newest.insert(item, at: index)
            if newest.count > limit { newest.removeLast() }
        }
        return newest
    }
}

@MainActor
@Observable
final class RecentDownloadsStore {
    typealias ScanResult = (folder: URL, files: [RecentDownload])
    typealias LoadFolder = @Sendable (Data) async throws -> ScanResult

    enum Phase: Equatable {
        case needsFolder, loading, ready, unavailable
    }

    private(set) var bookmark: Data?
    private(set) var folderURL: URL?
    private(set) var entries: [RecentDownload] = []
    private(set) var phase: Phase

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bookmarks: BookmarkService
    @ObservationIgnored private let loadFolder: LoadFolder
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var scanTask: Task<ScanResult, Error>?
    static let bookmarkKey = "OpenYoink.recentDownloadsFolder"

    init(defaults: UserDefaults, bookmarks: BookmarkService, loadFolder: LoadFolder? = nil) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.loadFolder = loadFolder ?? { data in
            let folder = try bookmarks.resolve(data).url
            return try bookmarks.withSecurityScopedAccess(to: folder) {
                (folder, try RecentDownloadsScanner.scan(folder))
            }
        }
        let stored = defaults.data(forKey: Self.bookmarkKey)
        self.bookmark = stored
        self.phase = stored == nil ? .needsFolder : .loading
    }

    func chooseFolder(_ url: URL) throws {
        let data = try bookmarks.withSecurityScopedAccess(to: url) {
            try bookmarks.createBookmark(for: url)
        }
        cancelScan()
        entries = []
        folderURL = nil
        bookmark = data
        defaults.set(data, forKey: Self.bookmarkKey)
        phase = .loading
    }

    func forgetFolder() {
        cancelScan()
        bookmark = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        entries = []
        folderURL = nil
        phase = .needsFolder
    }

    func refresh() async {
        guard let bookmark, !Task.isCancelled else { return }
        cancelScan()
        let id = UUID()
        scanID = id
        phase = .loading
        let worker = Task.detached(priority: .utility) { [loadFolder] in
            try Task.checkCancellation()
            return try await loadFolder(bookmark)
        }
        scanTask = worker
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        guard scanID == id else { return }
        scanTask = nil
        scanID = nil
        guard !Task.isCancelled else { return }
        switch result {
        case let .success((folder, files)):
            folderURL = folder
            entries = files
            phase = .ready
        case .failure:
            folderURL = nil
            entries = []
            phase = .unavailable
        }
    }

    private func cancelScan() {
        scanID = nil
        scanTask?.cancel()
        scanTask = nil
    }

    func withFile<T>(_ item: RecentDownload, _ action: (URL) throws -> T) rethrows -> T? {
        guard let bookmark,
              let folder = try? bookmarks.resolve(bookmark).url,
              entries.contains(item),
              folder.standardizedFileURL.path == item.url.deletingLastPathComponent().standardizedFileURL.path
        else { return nil }
        return try bookmarks.withSecurityScopedAccess(to: folder) {
            // Rebuild the URL so resource values cached by the scan cannot
            // authorize a file that has since disappeared or become a link.
            let url = folder.appendingPathComponent(item.url.lastPathComponent, isDirectory: false)
            guard RecentDownloadsScanner.entry(at: url) != nil else { return nil }
            return try action(url)
        }
    }

    func makeShelfItem(_ item: RecentDownload) throws -> ShelfItem? {
        try withFile(item) { url in
            ShelfItem(kind: DropImportCoordinator.inferFileKind(for: url),
                      path: url.path, bookmark: try bookmarks.createBookmark(for: url),
                      displayName: url.lastPathComponent)
        }
    }
}
