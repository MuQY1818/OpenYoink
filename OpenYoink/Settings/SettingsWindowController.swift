import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let hotKeyMonitor: HotKeyMonitor
    private let launchAtLoginController: LaunchAtLoginController
    private let updateController: UpdateController
    private let storageManagementController: StorageManagementController
    private let navigation: SettingsNavigationModel
    private let supportController: SupportController
    private let clipboardHistoryStore: ClipboardHistoryStore
    private var window: NSWindow?

    init(settings: SettingsStore,
         hotKeyMonitor: HotKeyMonitor,
         launchAtLoginController: LaunchAtLoginController,
         updateController: UpdateController,
         storageManagementController: StorageManagementController,
         navigation: SettingsNavigationModel,
         supportController: SupportController,
         clipboardHistoryStore: ClipboardHistoryStore) {
        self.settings = settings
        self.hotKeyMonitor = hotKeyMonitor
        self.launchAtLoginController = launchAtLoginController
        self.updateController = updateController
        self.storageManagementController = storageManagementController
        self.navigation = navigation
        self.supportController = supportController
        self.clipboardHistoryStore = clipboardHistoryStore
    }

    func show(pane: SettingsPane? = nil) {
        if let pane {
            navigation.selectedPane = pane
            if pane == .storage {
                storageManagementController.refresh()
            }
        }
        if window == nil {
            let rootView = SettingsView()
                .environment(settings)
                .environment(hotKeyMonitor)
                .environment(launchAtLoginController)
                .environment(updateController)
                .environment(storageManagementController)
                .environment(navigation)
                .environment(supportController)
                .environment(clipboardHistoryStore)
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.view.setAccessibilityLabel(
                String(localized: "OpenYoink Settings")
            )

            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "OpenYoink Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // A stable minimum sidebar width; the window may grow, so long text and
            // accessibility sizes get room instead of crowding the toolbar.
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OpenYoinkSettings")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
