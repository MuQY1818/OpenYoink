import Foundation

enum ShelfContentFilter: String, CaseIterable, Identifiable {
    case all, files, text, links, images
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .files: String(localized: "Files & Folders")
        case .text: String(localized: "Text")
        case .links: String(localized: "Links")
        case .images: String(localized: "Images")
        }
    }
    func matches(_ item: ShelfItem, query: String) -> Bool {
        if item.kind == .stack {
            return (item.children ?? []).contains { matches($0, query: query) }
                || (self == .all && !query.isEmpty && item.displayName.localizedCaseInsensitiveContains(query))
        }
        let kindMatches: Bool
        switch (self, item.kind) {
        case (.all, _), (.files, .file), (.files, .folder), (.text, .text), (.links, .url), (.images, .image):
            kindMatches = true
        default: kindMatches = false
        }
        return kindMatches && (query.isEmpty || [item.displayName, item.text ?? "", item.urlString ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) })
    }
}
