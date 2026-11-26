import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let isShelfExpanded: () -> Bool
    private let recents: RecentItemsService
    private let onToggleShelf: () -> Void
    /// Puts a recent item back on the shelf.
    private let onReaddRecent: (RecentEntry) -> Void
    private let onShowSettings: () -> Void
    private let onShowClipboardHistory: () -> Void
    private let onSaveClipboardImage: () -> Void
    /// Replays the two-step drag exercise.
    private let onShowQuickStart: () -> Void
    /// Opens the public usage help; changes no state.
    private let onOpenHelp: () -> Void
    /// Opens a GitHub issue prefilled with a diagnostics summary free of content
/// and paths.
    private let onReportIssue: () -> Void
    /// A manual Sparkle check.
    private let onCheckForUpdates: () -> Void
    /// Opens GitHub Releases when installing automatically failed.
    private let onOpenManualUpdate: () -> Void

    private let statusItem: NSStatusItem
    private let toggleItem = NSMenuItem()
    /// Rebuilt every time the menu opens (entries change with every drag out).
    private let recentParentItem = NSMenuItem()

    init(isShelfExpanded: @escaping () -> Bool,
         recents: RecentItemsService,
         onToggleShelf: @escaping () -> Void,
         onReaddRecent: @escaping (RecentEntry) -> Void,
         onShowSettings: @escaping () -> Void,
         onShowQuickStart: @escaping () -> Void,
         onOpenHelp: @escaping () -> Void,
         onReportIssue: @escaping () -> Void,
         onCheckForUpdates: @escaping () -> Void,
         onOpenManualUpdate: @escaping () -> Void,
         onShowClipboardHistory: @escaping () -> Void = {},
         onSaveClipboardImage: @escaping () -> Void = {}) {
        self.isShelfExpanded = isShelfExpanded
        self.recents = recents
        self.onToggleShelf = onToggleShelf
        self.onReaddRecent = onReaddRecent
        self.onShowSettings = onShowSettings
        self.onShowClipboardHistory = onShowClipboardHistory
        self.onSaveClipboardImage = onSaveClipboardImage
        self.onShowQuickStart = onShowQuickStart
        self.onOpenHelp = onOpenHelp
        self.onReportIssue = onReportIssue
        self.onCheckForUpdates = onCheckForUpdates
        self.onOpenManualUpdate = onOpenManualUpdate

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        configureMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // A template symbol, so the system tints it for light and dark menu bars
        // and the highlight.
        let image = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                            accessibilityDescription: "OpenYoink")
        image?.isTemplate = true
        button.image = image
        button.imageScaling = .scaleProportionallyDown
    }

    private func configureMenu() {
        let menu = NSMenu()

        toggleItem.action = #selector(toggleShelf(_:))
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Recent drag-outs (rebuilt on every open, see rebuildRecentSubmenu).
        recentParentItem.title = String(localized: "Recent Items")
        recentParentItem.submenu = NSMenu()
        menu.addItem(recentParentItem)

        let clipboardItem = NSMenuItem(title: String(localized: "Clipboard History…"),
                                       action: #selector(showClipboardHistory(_:)), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        let saveImageItem = NSMenuItem(title: String(localized: "Add Clipboard Image to Shelf"),
                                       action: #selector(saveClipboardImage(_:)), keyEquivalent: "")
        saveImageItem.target = self
        menu.addItem(saveImageItem)

        menu.addItem(.separator())

        let quickStartItem = NSMenuItem(title: String(localized: "Quick Start…"),
                                        action: #selector(showQuickStart(_:)),
                                        keyEquivalent: "")
        quickStartItem.target = self
        menu.addItem(quickStartItem)

        let helpItem = NSMenuItem(title: String(localized: "Usage Help"),
                                  action: #selector(openHelp(_:)),
                                  keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let reportItem = NSMenuItem(title: String(localized: "Report an Issue…"),
                                    action: #selector(reportIssue(_:)),
                                    keyEquivalent: "")
        reportItem.target = self
        menu.addItem(reportItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"),
                                      action: #selector(showSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Manual update check (automatic checks are in Settings › General).
        let updateItem = NSMenuItem(title: String(localized: "Check for Updates…"),
                                    action: #selector(checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let manualUpdateItem = NSMenuItem(title: String(localized: "Download Latest Release…"),
                                          action: #selector(openManualUpdate(_:)),
                                          keyEquivalent: "")
        manualUpdateItem.target = self
        menu.addItem(manualUpdateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit OpenYoink"),
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleShelf(_ sender: NSMenuItem) {
        onToggleShelf()
    }

    /// Opens the self-managed `SettingsWindowController`.
    ///
    /// Not SwiftUI's `showSettingsWindow:`: in an agent (LSUIElement) app that
    /// responder-chain action silently does nothing. The window controller
    /// handles activation.
    @objc private func showSettings(_ sender: Any?) {
        onShowSettings()
    }

    @objc private func showClipboardHistory(_ sender: Any?) {
        onShowClipboardHistory()
    }

    @objc private func saveClipboardImage(_ sender: Any?) {
        onSaveClipboardImage()
    }

    @objc private func showQuickStart(_ sender: Any?) {
        onShowQuickStart()
    }

    @objc private func openHelp(_ sender: Any?) {
        onOpenHelp()
    }

    @objc private func reportIssue(_ sender: Any?) {
        onReportIssue()
    }

    /// A manual Sparkle check (an empty feed safely reports up to date).
    @objc private func checkForUpdates(_ sender: Any?) {
        onCheckForUpdates()
    }

    @objc private func openManualUpdate(_ sender: Any?) {
        onOpenManualUpdate()
    }

    // MARK: - Recent Items submenu

    /// Newest first (`RecentItemsService` caps it at 20), with kind icons.
    /// Entries that can't be accessed or faithfully restored (a text summary)
    /// are disabled; "Clear Recent" comes last.
    private func rebuildRecentSubmenu() {
        guard let submenu = recentParentItem.submenu else { return }
        submenu.removeAllItems()
        let entries = recents.entries
        guard !entries.isEmpty else {
            let emptyItem = NSMenuItem(title: String(localized: "No Recent Items"),
                                       action: nil,
                                       keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.displayName,
                                  action: #selector(readdRecent(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.image = Self.menuIcon(for: entry)
            item.isEnabled = Self.canReadd(entry)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let clearItem = NSMenuItem(title: String(localized: "Clear Recent"),
                                   action: #selector(clearRecent(_:)),
                                   keyEquivalent: "")
        clearItem.target = self
        submenu.addItem(clearItem)
    }

    /// Files need a readable path (no sandbox access → disabled); URLs must
    /// parse. Text keeps only a 100-character summary and stacks were expanded
    /// on drag, so neither can be restored faithfully.
    nonisolated static func canReadd(_ entry: RecentEntry) -> Bool {
        switch entry.kind {
        case .file, .folder, .image:
            guard let path = entry.path else { return false }
            return FileManager.default.isReadableFile(atPath: path)
        case .url:
            return entry.urlString.flatMap(URL.init(string:)) != nil
        case .text, .stack:
            return false
        }
    }

    /// 16 pt icons: workspace icons for files, symbols otherwise.
    private static func menuIcon(for entry: RecentEntry) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        let image: NSImage?
        if let path = entry.path, FileManager.default.fileExists(atPath: path) {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let symbolName = switch entry.kind {
            case .file: "doc"
            case .folder: "folder"
            case .image: "photo"
            case .text: "doc.text"
            case .url: "link"
            case .stack: "square.stack.3d.up"
            }
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        image?.size = size
        return image
    }

    @objc private func readdRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentEntry,
              Self.canReadd(entry) else { return }
        onReaddRecent(entry)
    }

    @objc private func clearRecent(_ sender: NSMenuItem) {
        recents.clear()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// On every open: refresh the check mark and title (from the shelf's real
    /// visibility) and rebuild Recent Items.
    func menuWillOpen(_ menu: NSMenu) {
        let isVisible = isShelfExpanded()
        toggleItem.title = isVisible
            ? String(localized: "Hide Shelf")
            : String(localized: "Show Shelf")
        toggleItem.state = isVisible ? .on : .off
        rebuildRecentSubmenu()
    }
}
