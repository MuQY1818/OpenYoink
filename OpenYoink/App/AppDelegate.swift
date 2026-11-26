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

    /// 按 `SettingsStore.language` 覆盖 `AppleLanguages`；`.system` 时移除覆盖，
    /// 完全交还系统语言列表。
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
        // 必须在 Sparkle start 或任何新版本偏好写入之前采样，才能区分真正
        // 全新安装与没有 onboardingVersion 键的旧版本升级。
        let hasLegacyInstallEvidence = services.maintenance.legacyInstallEvidence()
        _ = services.menuBarController
        if !AppPaths.isUITesting { services.clipboardHistoryStore.start() }
        // EdgeTab: 拉环随启动就位（shelf 初始隐藏，拉环立即在边缘就位）。
        let edgeTab = services.edgeTabController
        services.shelfWindowController.onClassicShelfHandoffChanged = { [weak edgeTab] in
            edgeTab?.synchronizeShelfHandoff()
        }
        // Sparkle: 启动 updater（应用「自动检查」设置后 start；幂等）。
        if !AppPaths.isUITesting {
            services.updateController.start()
        }
        // UX1: 成功导入（拖入/剪贴板保存）→ 标记拖拽自动唤出会话「本轮
        // 已有内容落入」，拖结束时不再自动收回。
        services.dropImportCoordinator.onImportHandled = { [weak self] in
            self?.services.dragAutoShowSession.noteImport()
            self?.services.shelfWindowController.promoteClassicHoverPreviewIfNeeded()
        }
        services.shelfWindowController.onClassicDestinationEntered = { [weak self] sequenceNumber in
            self?.services.dragAutoShowSession.destinationEntered(sequenceNumber: sequenceNumber)
        }
        services.shelfWindowController.onClassicDestinationEnded = { [weak self] sequenceNumber, accepted in
            guard let self else { return }
            if self.services.dragAutoShowSession.destinationEnded(sequenceNumber: sequenceNumber, accepted: accepted),
               self.services.appState.isShelfVisible {
                self.services.shelfPresentationCoordinator.hideClassic(animated: true)
            }
        }
        services.shelfWindowController.onClassicPresentationRequested = { [weak self] in
            self?.services.dragAutoShowSession.cancelAutomaticHide()
        }
        if !AppPaths.isUITesting {
            services.applyTriggerSettings()
        }
        services.shelfPresentationCoordinator.applyCurrentMode(animated: false)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(userDefaultsDidChange(_:)),
                                               name: UserDefaults.didChangeNotification,
                                               object: nil)
        services.maintenance.run()
        // 引导必须排在 shelf 读取、事务恢复、bookmark 解析和安全清理之后，
        // 此时「空架」才是可信事实。
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

    /// 应用已在运行时再次打开（Finder / 启动台 / Spotlight 双击）：弹出设置。
    /// 菜单栏图标太多时 macOS 会把 OpenYoink 的图标藏起来且不提示，这是
    /// 此时唯一能找到的入口。
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
        services.shelfPresentationCoordinator.shutdown()
        services.onboardingController.applicationWillTerminate()
        services.maintenance.finish()
        services.stopTriggers()
    }

    @objc private nonisolated func userDefaultsDidChange(_ notification: Notification) {
        Task { @MainActor in
            services.applyTriggerSettings()
            services.shelfPresentationCoordinator.applyCurrentMode(animated: true)
            services.updateController.applySettings()
            services.clipboardHistoryStore.prune(force: true)
            services.clipboardHistoryStore.updateRecording()
        }
    }
}
