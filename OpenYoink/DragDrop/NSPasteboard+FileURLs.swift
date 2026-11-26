import AppKit

extension NSPasteboard {
    /// File URLs on the pasteboard, in pasteboard order.
    func fileURLs() -> [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { ($0 as? NSURL).map { $0 as URL } }
    }
}
