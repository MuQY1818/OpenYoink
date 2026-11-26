import AppKit
import OSLog
import QuickLookUI
import SwiftUI

enum QuickLookPreviewPlanner {
    /// The final, flattened and filtered set.
    static func previewItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        baseItems(selection: selection, contextItem: contextItem).flattened
            .filter { !$0.isStale }
    }

    /// Where `contextItem` sits in the flattened set; 0 when absent.
    static func currentIndex(in previewItems: [ShelfItem], contextItem: ShelfItem?) -> Int {
        guard let contextItem,
              let index = previewItems.firstIndex(where: { $0.id == contextItem.id }) else {
            return 0
        }
        return index
    }

    /// Rules 1–3 before flattening and filtering.
    static func baseItems(selection: [ShelfItem], contextItem: ShelfItem?) -> [ShelfItem] {
        if let contextItem, !selection.contains(where: { $0.id == contextItem.id }) {
            return [contextItem]
        }
        if !selection.isEmpty {
            return selection
        }
        return contextItem.map { [$0] } ?? []
    }

}

// MARK: - Item actions (Open / Show in Finder)

/// Item operations (open, show in Finder) and their availability.
///
/// Stateless; `canX` drives both the disabled state of menu items and the
/// tests. Nothing is available for an unavailable item, and no operation
/// ever deletes a user's original file.
@MainActor
enum ItemActions {
    // MARK: Availability

    /// Files, folders and images need an available path; text needs content;
    /// a URL needs its string (previewed as a temporary .txt); a stack needs one
    /// previewable child.
    static func canQuickLook(_ item: ShelfItem) -> Bool {
        switch item.kind {
        case .file, .folder, .image:
            return !item.isStale && item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return !(item.urlString?.isEmpty ?? true)
        case .stack:
            return (item.children ?? []).contains(where: canQuickLook)
        }
    }

    /// Files, folders and images open their resolved URL; text opens as a
    /// temporary .txt; a URL opens directly. Stacks can't be opened.
    static func canOpen(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url:
            return item.urlString.flatMap(URL.init(string:)) != nil
        case .stack:
            return false
        }
    }

    /// Files, folders and images reveal their resolved URL; text reveals its
    /// temporary .txt. A URL has no local file and a stack no single one.
    static func canRevealInFinder(_ item: ShelfItem) -> Bool {
        guard !item.isStale else { return false }
        switch item.kind {
        case .file, .folder, .image:
            return item.fileURL != nil
        case .text:
            return !(item.text?.isEmpty ?? true)
        case .url, .stack:
            return false
        }
    }

    // MARK: Actions

    /// No-op when `canOpen` is false.
    static func open(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canOpen(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            // Take security-scoped access before handing the URL to Launch Services.
            bookmarkService.withSecurityScopedAccess(to: url) {
                _ = NSWorkspace.shared.open(url)
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.open(url)
        case .url:
            guard let urlString = item.urlString, let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        case .stack:
            break
        }
    }

    /// No-op when `canRevealInFinder` is false.
    static func revealInFinder(_ item: ShelfItem, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        guard canRevealInFinder(item) else { return }
        switch item.kind {
        case .file, .folder, .image:
            guard let url = resolveFileURL(for: item, bookmarkService: bookmarkService) else { return }
            bookmarkService.withSecurityScopedAccess(to: url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .text:
            guard let text = item.text,
                  let url = try? writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                          tempFileService: tempFileService) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .url, .stack:
            break
        }
    }

    static func resolveFileURL(for item: ShelfItem, bookmarkService: BookmarkService) -> URL? {
        if let bookmark = item.bookmark {
            return try? bookmarkService.resolve(bookmark).url
        }
        return item.fileURL
    }

    static func writeTextToTemporaryFile(_ text: String, suggestedName: String, tempFileService: TempFileService) throws -> URL {
        // `uniqueFileURL` sanitizes the name and adds a UUID prefix.
        let url = try tempFileService.uniqueFileURL(suggestedName: suggestedName + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - QuickLookCoordinator

@MainActor
final class QuickLookCoordinator: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    /// One previewed item: its source and its Quick Look item with session resources.
    private struct PreviewEntry {
        let source: ShelfItem
        let previewItem: ShelfPreviewItem
    }

    private let store: ShelfStore
    private let bookmarkService: BookmarkService
    private let tempFileService: TempFileService
    private let logger = Log.make(category: "QuickLook")

    private var sharedPanel: QLPreviewPanel? { QLPreviewPanel.shared() }

    /// The current, flattened session. `session.map(\.source)` tells whether the
    /// same set was triggered again (toggle off).
    private var session: [PreviewEntry] = []
    /// Installed once, lazily, so launch doesn't create the shared panel.
    private var didInstallCloseObserver = false

    /// After the user closes the panel; the shelf panel becomes key again so
    /// Space works once more.
    var onPanelClosed: (() -> Void)?

    init(store: ShelfStore, bookmarkService: BookmarkService, tempFileService: TempFileService) {
        self.store = store
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isPreviewing: Bool {
        guard !session.isEmpty else { return false }
        return sharedPanel?.isVisible ?? false
    }

    // MARK: - Session control

    @discardableResult
    func toggle(contextItem: ShelfItem?) -> Bool {
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        let panelVisible = !session.isEmpty && (sharedPanel?.isVisible ?? false)
        if panelVisible, sourceItems == session.map(\.source) {
            dismiss()
            return true
        }
        guard !sourceItems.isEmpty else {
            if panelVisible { dismiss() }
            return false
        }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: true)
        return !session.isEmpty
    }

    /// Follows selection changes while the panel is open. A now-empty selection
    /// keeps the current session (clearing the selection shouldn't close what
    /// the user is looking at). Never takes keyboard focus.
    func refreshPreview(contextItem: ShelfItem?) {
        guard !session.isEmpty, sharedPanel?.isVisible == true else { return }
        let sourceItems = QuickLookPreviewPlanner.previewItems(selection: store.selectedItems,
                                                               contextItem: contextItem)
        guard !sourceItems.isEmpty, sourceItems != session.map(\.source) else { return }
        present(sourceItems, contextItem: contextItem, grabKeyFocus: false)
    }

    /// A user close (Space toggle, Esc): closes the panel, releases the session
    /// and makes the shelf panel key again.
    func dismiss() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
        onPanelClosed?()
    }

    /// On shelf hide: closes and releases without restoring focus, since the
    /// panel is sliding out.
    func closeForShelfHide() {
        guard !session.isEmpty else { return }
        if let panel = sharedPanel, panel.isVisible {
            panel.orderOut(nil)
        }
        endSession()
    }

    // MARK: - Session internals

    private func present(_ sourceItems: [ShelfItem], contextItem: ShelfItem?, grabKeyFocus: Bool) {
        buildSession(from: sourceItems)
        guard !session.isEmpty, let panel = sharedPanel else { return }
        installCloseObserverIfNeeded()
        // The panel is shared; point it at this coordinator for every session.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = QuickLookPreviewPlanner.currentIndex(
            in: session.map(\.source), contextItem: contextItem
        )
        if grabKeyFocus || !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Releases the previous session first. An item that fails to resolve is
    /// logged and skipped.
    private func buildSession(from sourceItems: [ShelfItem]) {
        endSession()
        var entries: [PreviewEntry] = []
        for item in sourceItems {
            if let previewItem = makePreviewItem(for: item) {
                entries.append(PreviewEntry(source: item, previewItem: previewItem))
            } else {
                logger.error("Skipping Quick Look item '\(item.displayName, privacy: .public)': could not resolve a preview URL")
            }
        }
        session = entries
    }

    /// Balances `stopAccessing` and deletes the session's temporary files.
    private func endSession() {
        for entry in session {
            if let accessedURL = entry.previewItem.accessedURL {
                bookmarkService.stopAccessing(accessedURL)
            }
            if let temporaryFileURL = entry.previewItem.temporaryFileURL {
                try? tempFileService.removeMaterializedFile(at: temporaryFileURL)
            }
        }
        session = []
    }

    /// See "Content" in the type comment.
    private func makePreviewItem(for item: ShelfItem) -> ShelfPreviewItem? {
        switch item.kind {
        case .file, .folder, .image:
            guard let url = ItemActions.resolveFileURL(for: item, bookmarkService: bookmarkService) else {
                return nil
            }
            // Access is held for the session and balanced in `endSession`. When start
            // fails, BookmarkService has already rolled its count back.
            let accessedURL = bookmarkService.startAccessing(url) ? url : nil
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: accessedURL, temporaryFileURL: nil)
        case .text:
            guard let text = item.text, !text.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(text, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .url:
            // Nothing is downloaded (see the type comment): preview the URL as text.
            guard let urlString = item.urlString, !urlString.isEmpty,
                  let url = try? ItemActions.writeTextToTemporaryFile(urlString, suggestedName: item.displayName,
                                                                      tempFileService: tempFileService) else {
                return nil
            }
            return ShelfPreviewItem(url: url, title: item.displayName,
                                    accessedURL: nil, temporaryFileURL: url)
        case .stack:
            // Stacks were expanded by QuickLookPreviewPlanner; defensive.
            return nil
        }
    }

    // MARK: - Panel close observation

    private func installCloseObserverIfNeeded() {
        guard !didInstallCloseObserver else { return }
        didInstallCloseObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: QLPreviewPanel.shared()
        )
    }

    @objc private func panelWillClose(_ notification: Notification) {
        endSession()
        onPanelClosed?()
    }
}

// MARK: - QLPreviewPanelDataSource / QLPreviewPanelDelegate

/// The conformance is declared on the class (see its comment). No delegate
/// methods: the default zoom transition and key handling suffice.
extension QuickLookCoordinator {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        session.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard session.indices.contains(index) else { return nil }
        return session[index].previewItem
    }
}

// MARK: - ShelfPreviewItem

/// A preview item that also carries its session resources (security-scoped
/// access, temporary files), released by the coordinator at session end.
private final class ShelfPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    /// nil when not needed or when start failed.
    let accessedURL: URL?
    /// A temporary .txt (text and URL previews), deleted at session end.
    let temporaryFileURL: URL?

    init(url: URL, title: String, accessedURL: URL?, temporaryFileURL: URL?) {
        self.previewItemURL = url
        self.previewItemTitle = title
        self.accessedURL = accessedURL
        self.temporaryFileURL = temporaryFileURL
        super.init()
    }
}

// MARK: - SwiftUI environment

struct ShelfFileServices: Sendable {
    let bookmarks: BookmarkService
    let tempFiles: TempFileService
}

extension EnvironmentValues {
    @Entry var quickLookCoordinator: QuickLookCoordinator? = nil
    @Entry var shelfFileServices: ShelfFileServices? = nil
}
