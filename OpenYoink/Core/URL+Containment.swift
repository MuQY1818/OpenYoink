import Foundation

extension URL {
    /// Whether this file URL lies strictly inside `directory`.
    ///
    /// Paths are standardized first; with `resolvingSymlinks` they are also
    /// resolved so `/var` and `/private/var` compare equal.
    func isContained(in directory: URL, resolvingSymlinks: Bool = true) -> Bool {
        func normalized(_ url: URL) -> String {
            let standardized = url.standardizedFileURL
            return (resolvingSymlinks ? standardized.resolvingSymlinksInPath() : standardized).path
        }
        let root = normalized(directory)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return normalized(self).hasPrefix(prefix)
    }
}
