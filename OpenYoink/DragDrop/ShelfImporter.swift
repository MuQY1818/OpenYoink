import AppKit
import OSLog

@MainActor
final class ShelfImporter {
    private let logger = Log.make(category: "ShelfImport")
    private let shelfStore: ShelfStore
    private let dropImportCoordinator: DropImportCoordinator
    private let appState: AppState
    private let shelfNotice: ShelfNoticeModel
    private let bookmarkService: BookmarkService
    private let shelfWindowController: ShelfWindowController

    init(shelfStore: ShelfStore,
         dropImportCoordinator: DropImportCoordinator,
         appState: AppState,
         shelfNotice: ShelfNoticeModel,
         bookmarkService: BookmarkService,
         shelfWindowController: ShelfWindowController) {
        self.shelfStore = shelfStore
        self.dropImportCoordinator = dropImportCoordinator
        self.appState = appState
        self.shelfNotice = shelfNotice
        self.bookmarkService = bookmarkService
        self.shelfWindowController = shelfWindowController
    }

    // MARK: - clipboard save

    func saveClipboardToShelf() {
        let result = importItems(from: .general)
        guard result.handled else {
            if appState.isShelfVisible {
                shelfNotice.show(String(localized: "Clipboard is empty or has nothing the shelf can hold."))
            }
            return
        }
        shelfWindowController.showPreferredShelf(animated: true)
    }

    func saveClipboardImageToShelf() {
        let scheduled = dropImportCoordinator.importClipboardImages(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        shelfWindowController.showPreferredShelf(animated: true)
        if scheduled == 0 {
            shelfNotice.show(String(localized: "No supported image on the clipboard."))
        }
    }

    // MARK: - Recent items re-add

    func addHistoryToShelf(_ content: ClipboardHistoryEntry.Content) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        switch content {
        case .text(let value): item.setString(value, forType: .string)
        case .url(let value): item.setString(value, forType: .URL)
        case .image(let data, let type): item.setClipboardHistoryImage(data, type: type)
        }
        pasteboard.writeObjects([item])
        let result = importItems(from: pasteboard)
        guard result.handled else { return }
        shelfWindowController.showPreferredShelf(animated: true)
    }

    func readdRecent(_ entry: RecentEntry) {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return }
            let item = DropImportCoordinator.makeFileBackedItem(
                for: URL(fileURLWithPath: path),
                displayName: entry.displayName,
                bookmarkService: bookmarkService,
                logger: logger
            )
            shelfStore.add(item)
        case .url:
            guard let urlString = entry.urlString else { return }
            shelfStore.add(ShelfItem(kind: .url,
                                     displayName: entry.displayName,
                                     urlString: urlString))
        case .text, .stack:
            return
        }
        shelfWindowController.showPreferredShelf(animated: true)
    }

    private func importItems(from pasteboard: NSPasteboard) -> DropImportResult {
        let result = dropImportCoordinator.importItems(from: pasteboard) { [weak shelfStore] item in
            shelfStore?.add(item)
        }
        shelfStore.add(contentsOf: result.items)
        return result
    }
}
