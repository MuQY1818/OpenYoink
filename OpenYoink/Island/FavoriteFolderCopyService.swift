import Foundation

enum FolderCopyConflictDecision: Sendable { case keepBoth, skip, cancel }
struct FolderCopyResult: Equatable, Sendable {
    var copied = 0
    var skipped = 0
    var failed = 0
    var cancelled = 0
}

/// Copy to a staging directory on the target volume, then commit without overwriting.
actor FavoriteFolderCopyService {
    private let bookmarks: BookmarkService
    init(bookmarks: BookmarkService) { self.bookmarks = bookmarks }

    func copy(_ sources: [Data], to destination: Data,
              conflict: @Sendable (String) async -> FolderCopyConflictDecision,
              progress: @Sendable (Int, Int) async -> Void) async -> FolderCopyResult {
        var result = FolderCopyResult()
        let manager = FileManager()
        guard let folder = try? bookmarks.resolve(destination).url else {
            result.failed = sources.count
            return result
        }
        bookmarks.startAccessing(folder)
        defer { bookmarks.stopAccessing(folder) }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            result.failed = sources.count
            return result
        }
        for (index, data) in sources.enumerated() {
            if Task.isCancelled { result.cancelled = sources.count - index; break }
            do {
                let source = try bookmarks.resolve(data).url
                bookmarks.startAccessing(source)
                defer { bookmarks.stopAccessing(source) }
                guard Self.isSafeDestination(folder, for: source) else {
                    result.failed += 1
                    await progress(index + 1, sources.count)
                    continue
                }
                var target = folder.appendingPathComponent(source.lastPathComponent)
                if Self.exists(target, manager: manager) {
                    switch await conflict(source.lastPathComponent) {
                    case .cancel: result.cancelled = sources.count - index; return result
                    case .skip:
                        result.skipped += 1
                        await progress(index + 1, sources.count)
                        continue
                    case .keepBoth: target = Self.uniqueTarget(for: target, manager: manager)
                    }
                }
                if Task.isCancelled { result.cancelled = sources.count - index; break }
                let staging = folder.appendingPathComponent(".openyoink-copy-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? manager.removeItem(at: staging) }
                let stagedFile = staging.appendingPathComponent(source.lastPathComponent)
                try manager.copyItem(at: source, to: stagedFile)
                if Task.isCancelled { result.cancelled = sources.count - index; break }
                do { try manager.moveItem(at: stagedFile, to: target); result.copied += 1 }
                catch CocoaError.fileWriteFileExists {
                    // A file may appear after the preflight. Never silently overwrite it.
                    switch await conflict(target.lastPathComponent) {
                    case .cancel: result.cancelled = sources.count - index; return result
                    case .skip: result.skipped += 1
                    case .keepBoth:
                        try manager.moveItem(at: stagedFile, to: Self.uniqueTarget(for: target, manager: manager))
                        result.copied += 1
                    }
                }
            } catch { result.failed += 1 }
            await progress(index + 1, sources.count)
        }
        return result
    }
    nonisolated static func isSafeDestination(_ folder: URL, for source: URL) -> Bool {
        guard folder.isFileURL, source.isFileURL, !source.lastPathComponent.isEmpty else { return false }
        return !folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            .starts(with: source.resolvingSymlinksInPath().standardizedFileURL.pathComponents)
    }
    private static func exists(_ url: URL, manager: FileManager) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }
    private static func uniqueTarget(for url: URL, manager: FileManager) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var index = 2
        var candidate: URL
        repeat {
            candidate = url.deletingLastPathComponent().appendingPathComponent(
                ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)")
            index += 1
        } while exists(candidate, manager: manager)
        return candidate
    }
}
