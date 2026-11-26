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
    private let shelfPresentationCoordinator: ShelfPresentationCoordinator

    init(shelfStore: ShelfStore,
         dropImportCoordinator: DropImportCoordinator,
         appState: AppState,
         shelfNotice: ShelfNoticeModel,
         bookmarkService: BookmarkService,
         shelfPresentationCoordinator: ShelfPresentationCoordinator) {
        self.shelfStore = shelfStore
        self.dropImportCoordinator = dropImportCoordinator
        self.appState = appState
        self.shelfNotice = shelfNotice
        self.bookmarkService = bookmarkService
        self.shelfPresentationCoordinator = shelfPresentationCoordinator
    }

    // MARK: - UX3 clipboard save

    /// 双击快捷键保存剪贴板：复用 `DropImportCoordinator` 的拖入分派（文件 /
    /// 图片 / URL / 文本）。成功导入即唤出 shelf 给出反馈；空剪贴板或无
    /// 可导入内容时不动作（shelf 可见时走既有 notice 提示）。
    func saveClipboardToShelf() {
        let result = importItems(from: .general)
        guard result.handled else {
            if appState.isShelfVisible {
                shelfNotice.show(String(localized: "Clipboard is empty or has nothing the shelf can hold."))
            }
            return
        }
        shelfPresentationCoordinator.show(animated: true)
    }

    func saveClipboardImageToShelf() {
        let scheduled = dropImportCoordinator.importClipboardImages(from: .general) { [weak self] item in
            self?.shelfStore.add(item)
        }
        shelfPresentationCoordinator.show(animated: true)
        if scheduled == 0 {
            shelfNotice.show(String(localized: "No supported image on the clipboard."))
        }
    }

    // MARK: - Recent items re-add (S10)

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
        shelfPresentationCoordinator.show(animated: true)
    }

    /// 菜单栏「最近项目」点击重新入架：文件类按路径重建 ShelfItem（含新的
    /// 安全书签；`canReadd` 已在菜单侧确认可访问），URL 直接复原。text/stack
    /// 条目在菜单侧已置灰，不会到达这里。入架后唤出 shelf 给出明确反馈。
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
        shelfPresentationCoordinator.show(animated: true)
    }

    private func importItems(from pasteboard: NSPasteboard) -> DropImportResult {
        let result = dropImportCoordinator.importItems(from: pasteboard) { [weak shelfStore] item in
            shelfStore?.add(item)
        }
        shelfStore.add(contentsOf: result.items)
        return result
    }
}
