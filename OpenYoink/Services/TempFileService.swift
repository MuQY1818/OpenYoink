import Foundation
import OSLog

/// Manages the directory where dragged-in file promises and raw data are
/// materialized (`Application Support/OpenYoink/Materialized` in the sandbox
/// container).
///
/// Everything inside the directory is owned by the app: safe to create, move
/// and delete. The service never touches user files outside this directory —
/// deletion APIs refuse URLs outside it.
final class TempFileService: Sendable {
    enum TempFileServiceError: Error, Equatable {
        /// Refused to delete a file outside the managed directory.
        case outsideManagedDirectory(URL)
    }

    struct CleanupResult: Equatable, Sendable {
        var removedItemCount = 0
        var reclaimedBytes: Int64 = 0
    }

    /// The managed materialization directory; inject a custom one in tests.
    let directoryURL: URL

    private static let promiseStagingPrefix = "PromiseStaging-"

    private let logger = Log.make(category: "TempFileService")

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppPaths.materialized()
    }

    /// Returns a unique, non-existent file URL inside the managed directory.
    /// The suggested name's extension is preserved (drag targets rely on it for
    /// UTI detection). Creates the directory if needed, but not the file itself.
    func uniqueFileURL(suggestedName: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let sanitized = URL(fileURLWithPath: suggestedName).lastPathComponent
        let name = sanitized.isEmpty ? "file" : sanitized
        var candidate = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        }
        return candidate
    }

    /// The staging directory shared by one batch of receivers. Its name matches
    /// the launch-time age rule; it is never removed during promise callbacks.
    func createPromiseStagingDirectory() throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent(
            Self.promiseStagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Deletes a materialized file (e.g. when its shelf item is removed).
    /// Throws `outsideManagedDirectory` for any URL outside the managed
    /// directory, so a caller bug can never delete a user's original file.
    func removeMaterializedFile(at url: URL) throws {
        guard url.isContained(in: directoryURL) else {
            throw TempFileServiceError.outsideManagedDirectory(url)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes everything in the managed directory except `keepingPaths` — the
    /// paths referenced by persisted shelf items. Call once at launch after
    /// loading the store; leftovers from a previous session (interrupted
    /// materializations) are orphans and get removed. Best-effort: individual
    /// failures are logged, not thrown.
    @discardableResult
    func cleanupOrphans(keepingPaths: Set<String> = []) -> CleanupResult {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return CleanupResult() // directory does not exist yet — nothing to clean
        }
        var result = CleanupResult()
        let keep = Set(keepingPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            guard !keep.contains(url.standardizedFileURL.path) else { continue }
            // A promise writer may still be writing into staging. The age rule below
            // reclaims it; orphan cleanup must never delete it unconditionally at launch.
            guard !name.hasPrefix(Self.promiseStagingPrefix) else { continue }
            do {
                let bytes = allocatedSize(of: url)
                try fileManager.removeItem(at: url)
                result.removedItemCount += 1
                result.reclaimedBytes += bytes
            } catch {
                logger.error("Failed to remove orphaned file \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    /// Current size of managed storage. A file that can't be read counts as 0,
    /// so a concurrent promise write can't break the settings page.
    func storageUsage() -> Int64 {
        allocatedSize(of: directoryURL)
    }

    private func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .totalFileSizeKey,
        ]
        let rootValues = try? url.resourceValues(forKeys: keys)
        if rootValues?.isRegularFile == true {
            return byteSize(from: rootValues)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return byteSize(from: rootValues)
        }
        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            let values = try? childURL.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += byteSize(from: values)
        }
        return total
    }

    private func byteSize(from values: URLResourceValues?) -> Int64 {
        let candidates = [
            values?.totalFileAllocatedSize,
            values?.fileAllocatedSize,
            values?.totalFileSize,
            values?.fileSize,
        ].compactMap { $0 }
        return Int64(candidates.first(where: { $0 > 0 }) ?? 0)
    }

    /// Removes shared promise staging directories (`PromiseStaging-*`) older
    /// than `maxAge` seconds (a recent drop may still have files in flight).
    /// Independent of shelf content, safe at launch; callbacks never clean up
    /// staging, this does (default one hour).
    func cleanupStaleStagingDirectories(maxAge: TimeInterval = 3600,
                                        keepingPaths: Set<String> = []) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let protected = keepingPaths.map { URL(fileURLWithPath: $0) }
        for name in names where name.hasPrefix(Self.promiseStagingPrefix) {
            let url = directoryURL.appendingPathComponent(name)
            guard !protected.contains(where: { $0.isContained(in: url, resolvingSymlinks: false) }) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard modified < cutoff else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Failed to remove stale staging dir \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
