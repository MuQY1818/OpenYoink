import AppKit

// MARK: - DragImageCache

@MainActor
enum DragImageCache {
    private static var images: [UUID: CGImage] = [:]
    private static let capacity = 256

    static func register(_ image: CGImage, for id: UUID) {
        if images.count >= capacity {
            images.removeAll()
        }
        images[id] = image
    }

    static func image(for id: UUID) -> CGImage? {
        images[id]
    }
}

// MARK: - BookmarkService environment
