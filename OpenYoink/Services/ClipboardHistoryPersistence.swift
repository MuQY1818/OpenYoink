import Foundation

actor ClipboardHistoryPersistence {
    private struct Snapshot: Codable {
        let version: Int
        let entries: [ClipboardHistoryEntry]
    }
    private let file: JSONFileStore<Index>
    private let imageDirectory: URL
    private struct StoredEntry: Codable {
        let id: UUID
        let copiedAt: Date
        let isFavorite: Bool
        let text: String?
        let isURL: Bool
        let imageType: String?
        let imageName: String?
    }
    private struct Index: Codable {
        let version: Int
        let entries: [StoredEntry]
    }
    private var latestRevision = 0

    init(directoryURL: URL) {
        file = JSONFileStore(directoryURL.appendingPathComponent("clipboard-history.json"))
        imageDirectory = directoryURL.appendingPathComponent("ClipboardImages", isDirectory: true)
    }

    func load() throws -> [ClipboardHistoryEntry] {
        guard FileManager.default.fileExists(atPath: file.url.path) else { return [] }
        let data = try file.readData(maximumBytes: ClipboardHistoryPolicy.maximumEncodedBytes)
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        if version == 1 {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.entries.count <= ClipboardHistoryPolicy.maximumEntries else { throw CocoaError(.coderReadCorrupt) }
            // The first subsequent save migrates atomically; reading never destroys the old file.
            return snapshot.entries
        }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard version == 2, index.entries.count <= 330 else {
            throw CocoaError(.coderReadCorrupt)
        }
        var bytes = 0
        return try index.entries.map { item in
            let content: ClipboardHistoryEntry.Content
            if let type = item.imageType {
                let expected = item.id.uuidString + ".image"
                guard item.imageName == expected else { throw CocoaError(.fileReadCorruptFile) }
                let url = imageDirectory.appendingPathComponent(expected)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= ClipboardHistoryPolicy.maximumImageBytes else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                content = .image(try Data(contentsOf: url), type: type)
            } else if let value = item.text {
                content = item.isURL ? .url(value) : .text(value)
            } else { throw CocoaError(.fileReadCorruptFile) }
            bytes += content.byteCount
            guard content.isValid, bytes <= ClipboardHistoryPolicy.maximumTotalBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ClipboardHistoryEntry(id: item.id, copiedAt: item.copiedAt,
                                         content: content, isFavorite: item.isFavorite)
        }
    }

    func save(_ entries: [ClipboardHistoryEntry], revision: Int) throws {
        // Actor calls from different Tasks can arrive out of order. A clear or
        // delete must never be undone by an older queued snapshot.
        guard !Task.isCancelled, revision > latestRevision else { return }
        latestRevision = revision
        let manager = FileManager.default
        if entries.isEmpty {
            if manager.fileExists(atPath: file.url.path) { try manager.removeItem(at: file.url) }
            try removeUnusedImages(keeping: [])
            return
        }
        try manager.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: imageDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        var stored: [StoredEntry] = []
        for entry in entries {
            var text: String?
            var isURL = false
            var imageType: String?
            var imageName: String?
            switch entry.content {
            case .text(let value): text = value
            case .url(let value): text = value; isURL = true
            case .image(let data, let type):
                imageType = type
                imageName = entry.id.uuidString + ".image"
                let url = imageDirectory.appendingPathComponent(imageName!)
                if !manager.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
            stored.append(StoredEntry(id: entry.id, copiedAt: entry.copiedAt, isFavorite: entry.isFavorite,
                                      text: text, isURL: isURL, imageType: imageType, imageName: imageName))
        }
        try file.writeAtomically(Index(version: 2, entries: stored), formatting: [])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        // Clean attachments only after the new index is durably committed.
        try removeUnusedImages(keeping: Set(stored.compactMap(\.imageName)))
    }

    private func removeUnusedImages(keeping names: Set<String>) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: imageDirectory.path) else { return }
        for url in try manager.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
            where url.pathExtension == "image" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
                && !names.contains(url.lastPathComponent) {
            try manager.removeItem(at: url)
        }
    }
}
