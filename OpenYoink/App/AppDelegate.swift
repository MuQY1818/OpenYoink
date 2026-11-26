import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppPaths.isUITesting {
            // This is a fixed child of the app container's temporary
            // directory, selected only by the explicit UI-test environment.
            // Clearing it makes every launch deterministic without touching
            // the user's real Application Support data.
            try? FileManager.default.removeItem(at: AppPaths.applicationSupport())
        }
        if !AppPaths.isUITesting {
            applyLanguageOverride()
        }
    }

    private func applyLanguageOverride() {
        switch services.settingsStore.language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        case .chinese:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let hasLegacyInstallEvidence = services.maintenance.legacyInstallEvidence()
        _ = services.menuBarController
        if !AppPaths.isUITesting { services.clipboardHistoryStore.start() }
        services.connectShelfPresentation()
        if !AppPaths.isUITesting {
            services.updateController.start()
        }

        if !AppPaths.isUITesting {
            services.applyTriggerSettings()
        }
        services.shelfWindowController.applyPresentationSettings(animated: false)
        services.settingsStore.observeChanges { [weak services] in
            guard let services else { return }
            services.applyTriggerSettings()
            services.shelfWindowController.applyPresentationSettings(animated: true)
            services.edgeTabController.applyState(animated: true)
            services.updateController.applySettings()
            services.clipboardHistoryStore.prune(force: true)
            services.clipboardHistoryStore.updateRecording()
        }
        services.maintenance.run()

        if AppPaths.isUITesting {
            presentRequestedUITestSurface()
        } else {
            services.onboardingController.startAtLaunch(
                hasLegacyInstallEvidence: hasLegacyInstallEvidence
            )
        }
    }

    private func presentRequestedUITestSurface() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing-open-settings") {
            services.settingsWindowController.show(pane: .general)
        } else if arguments.contains("--ui-testing-show-shelf") {
            services.shelfWindowController.showShelf(animated: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services.settingsWindowController.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        services.clipboardHistoryStore.stop()
        Task { @MainActor in
            await services.clipboardHistoryStore.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.clipboardHistoryStore.stop()
        services.shelfWindowController.shutdown()
        services.onboardingController.applicationWillTerminate()
        services.maintenance.finish()
        services.stopTriggers()
    }
}
