import AppKit
import SwiftUI

@MainActor
final class ClipboardHistoryWindowController {
    private let history: ClipboardHistoryStore
    private let settings: SettingsStore
    private var window: NSWindow?

    init(history: ClipboardHistoryStore, settings: SettingsStore) {
        self.history = history
        self.settings = settings
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: ClipboardHistoryView()
                .padding(16).environment(history).environment(settings))
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "Clipboard History")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 460, height: 340)
            window.setContentSize(NSSize(width: 560, height: 460))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OpenYoinkClipboardHistory")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
