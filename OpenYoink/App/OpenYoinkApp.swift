import SwiftUI

@main
struct OpenYoinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar opens SettingsWindowController; this scene shows the
        // same content so the system "Settings…" command never opens a blank
        // window once the app is active.
        Settings {
            SettingsView()
                .environment(appDelegate.services.settingsStore)
                .environment(appDelegate.services.hotKeyMonitor)
                .environment(appDelegate.services.launchAtLoginController)
                .environment(appDelegate.services.updateController)
                .environment(appDelegate.services.storageManagementController)
                .environment(appDelegate.services.settingsNavigation)
                .environment(appDelegate.services.supportController)
                .environment(appDelegate.services.clipboardHistoryStore)
        }
    }
}
