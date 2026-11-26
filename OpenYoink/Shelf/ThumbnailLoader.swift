import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - ThumbnailLoader

enum ThumbnailLoader {

    @MainActor
    static func thumbnail(for item: ShelfItem, pointSize: CGSize, bookmarkService: BookmarkService) async -> Image? {
        guard let baseURL = item.fileURL else { return nil }
        var url = baseURL
        var accessedURL: URL?
        if let bookmark = item.bookmark,
           let resolved = try? bookmarkService.resolve(bookmark) {
            url = resolved.url
            if bookmarkService.startAccessing(url) {
                accessedURL = url
            }
        }
        defer {
            if let accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let cgImage = await quickLookThumbnail(for: url, pointSize: pointSize, scale: scale) {
            // Register with the drag image cache, read synchronously when a drag starts.
            DragImageCache.register(cgImage, for: item.id)
            return Image(decorative: cgImage, scale: scale)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var proposedRect = NSRect(origin: .zero, size: icon.size)
        if let cgIcon = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            DragImageCache.register(cgIcon, for: item.id)
        }
        return Image(nsImage: icon)
    }

    /// nil when the bundle ID is missing or can't be resolved.
    @MainActor
    static func sourceAppIcon(bundleID: String?) -> NSImage? {
        guard let bundleID,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private nonisolated static func quickLookThumbnail(for url: URL,
                                                       pointSize: CGSize,
                                                       scale: CGFloat) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: pointSize, scale: scale, representationTypes: .thumbnail
        )

        let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        return representation?.cgImage
    }
}
