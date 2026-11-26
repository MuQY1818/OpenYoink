import Foundation

extension URL {
    /// Whether this file URL lies strictly inside `directory`.
    ///
    /// Paths are standardized first; with `resolvingSymlinks` they are also
    /// resolved so `/var` and `/private/var` compare equal.
    nonisolated func isContained(in directory: URL, resolvingSymlinks: Bool = true,
                                 includingDirectory: Bool = false) -> Bool {
        func normalized(_ url: URL) -> String {
            let standardized = url.standardizedFileURL
            return (resolvingSymlinks ? standardized.resolvingSymlinksInPath() : standardized).path
        }
        let root = normalized(directory)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let path = normalized(self)
        return (includingDirectory && path == root) || (path != root && path.hasPrefix(prefix))
    }
}
