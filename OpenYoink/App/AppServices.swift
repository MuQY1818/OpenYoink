import AppKit

@MainActor
final class AppServices {
    private static let uiTestingDefaultsSuite = "com.weijue.OpenYoink.UITests"

    private static func makeSettingsDefaults() -> UserDefaults {
        guard AppPaths.isUITesting else { return .standard }
        guard let defaults = UserDefaults(suiteName: uiTestingDefaultsSuite) else {
            fatalError("Unable to create the isolated UI-testing defaults suite")
        }
        defaults.removePersistentDomain(forName: uiTestingDefaultsSuite)
        return defaults
    }

    let appState = AppState()
    /// JSON 持久化（原子写 + 500ms 防抖）；store 的一切变更经它落盘。
    private let persistence = PersistenceController()
    /// 安全书签服务（拖入创建 / 启动解析 / 缩略图与打开操作的访问权管理）。
    private let bookmarkService = BookmarkService()
    /// 物化临时文件目录（file promise 与图片数据落盘处）。
    private let tempFileService = TempFileService()
    /// v1.2: ⌘ 拖入托管移动的崩溃恢复事务。独立于 shelf.json，且其引用
    /// 必须参与所有 Materialized 清理保护集合。
    private let managedMoveJournal = ManagedMoveJournal()
    /// v1.2: file-promise staging/finalization recovery. Lazy construction
    /// keeps its managed root identical to TempFileService in every build.
    private lazy var pendingImportJournal = PendingImportJournal(
        managedDirectoryURL: tempFileService.directoryURL
    )
    /// S10: 拖入/物化失败的内联提示（shelf 标题栏下方短暂胶囊，自动消失）。
    private let shelfNotice = ShelfNoticeModel()
    private let transferStore = TransferStore()
    /// 仅承载活动 tutorial item 的 token，避免 shelf 与 onboarding lazy init 成环。
    private let onboardingDragContext = OnboardingDragContext()
    private var isUITesting: Bool {
        AppPaths.isUITesting
    }
    /// shelf.json 在整个启动链路中只读取一次。读取失败会隔离损坏文件；若再读
    /// 一次就会得到 `.missing`，从而错误放行 Materialized 孤儿清理。
    private lazy var initialShelfLoadResult = persistence.loadResult()
    /// Shelf 数据（S3 起由 AppDelegate 持有并注入 ShelfView）。
    private lazy var shelfStore = ShelfStore(items: initialShelfLoadResult.contents,
                                             persistence: persistence)
    /// S4: 拖入分派器（pasteboard → ShelfItem）。S10: 失败路径经 shelfNotice 反馈。
    lazy var dropImportCoordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                                   tempFileService: tempFileService,
                                                                   noticeCenter: shelfNotice,
                                                                   managedMoveJournal: managedMoveJournal,
                                                                   pendingImportJournal: pendingImportJournal,
                                                                   transferStore: transferStore)
    /// 用户设置（S5 起拖出后移除策略被 DragSessionController 读取；S8 由
    /// SettingsView 编辑）。internal：OpenYoinkApp 的 Settings scene 注入环境用。
    let settingsStore = SettingsStore(defaults: AppServices.makeSettingsDefaults())
    lazy var clipboardHistoryStore: ClipboardHistoryStore = {
        let history = ClipboardHistoryStore(settings: settingsStore)
        history.onAddToShelf = { [weak self] content in self?.shelfImporter.addHistoryToShelf(content) }
        history.onShowWindow = { [weak self] in self?.clipboardHistoryWindowController.show() }
        return history
    }()
    private lazy var clipboardHistoryWindowController = ClipboardHistoryWindowController(
        history: clipboardHistoryStore, settings: settingsStore
    )
    /// 设置窗口的共享导航状态，允许不可用的托管项目直接打开“存储”页。
    let settingsNavigation = SettingsNavigationModel()
    /// 系统登录项状态（不复制到 UserDefaults；SMAppService 是唯一事实源）。
    let launchAtLoginController = LaunchAtLoginController()
    /// 恢复快照、托管目录占用与安全清理（设置-存储）。
    lazy var storageManagementController = StorageManagementController(
        persistence: persistence,
        tempFileService: tempFileService,
        shelfStore: shelfStore,
        managedMoveJournal: managedMoveJournal,
        pendingImportJournal: pendingImportJournal,
        bookmarkService: bookmarkService,
        additionalProtectedPaths: { [weak self] in
            (self?.deliveryCoordinator.protectedMaterializedPaths ?? [])
                .union(self?.shelfStore.undoProtectedPaths ?? [])
                .union(self?.islandModules.favoriteFolderDropCoordinator.protectedPaths ?? [])
        },
        prepareRestoredItems: { [weak self] items in
            guard let self else { return items }
            return items.map { self.maintenance.refreshedByResolvingBookmark($0) ?? $0 }
        }
    )
    /// S5: 最近拖出历史（内存 + recents.json；S10 已接入菜单栏「最近项目」）。
    private let recentItemsService = RecentItemsService()
    /// v1.2: shared drag-out acceptance/promise-delivery coordinator. Storage
    /// cleanup consults its runtime file leases.
    private lazy var deliveryCoordinator = DeliveryCoordinator(
        store: shelfStore,
        recents: recentItemsService,
        tempFileService: tempFileService,
        transferStore: transferStore
    )
    /// Sparkle 2 自动更新封装（懒加载：首次 start/手动检查时创建
    /// SPUStandardUpdaterController；terminate 无需显式释放——XPC 连接与
    /// 调度器随进程终止，无后台常驻资源）。
    lazy var updateController = UpdateController(settings: settingsStore)
    /// Help, voluntary issue reporting and privacy-safe local diagnostics.
    lazy var supportController = SupportController(settings: settingsStore)

    private lazy var dropHandler = ShelfDropHandler(
        store: shelfStore, coordinator: dropImportCoordinator, notices: shelfNotice
    )
    private lazy var islandModules = IslandModules(
        settings: settingsStore, bookmarkService: bookmarkService, transferStore: transferStore
    )
    lazy var shelfWindowController: ShelfWindowController = ShelfWindowController(appState: appState,
                                                                   store: shelfStore,
                                                                   dropHandler: dropHandler,
                                                                   bookmarkService: bookmarkService,
                                                                   notices: shelfNotice,
                                                                   transferStore: transferStore,
                                                                   islandModules: islandModules,
                                                                   tempFileService: tempFileService,
                                                                   settings: settingsStore,
                                                                   recents: recentItemsService,
                                                                   deliveryCoordinator: deliveryCoordinator,
                                                                   dragStartMonitor: dragStartMonitor,
                                                                   clipboardHistoryStore: clipboardHistoryStore,
                                                                   onOpenSettings: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .general)
                                                                   },
                                                                   onOpenStorageRecovery: { [weak self] in
                                                                       self?.settingsWindowController.show(pane: .storage)
                                                                   },
                                                                   tutorialTokenForItem: { [weak self] itemID in
                                                                       self?.onboardingDragContext.token(for: itemID)
                                                                   })
    lazy var shelfPresentationCoordinator = ShelfPresentationCoordinator(
        windowController: shelfWindowController
    )
    lazy var onboardingController = OnboardingController(
        settings: settingsStore,
        shelfStore: shelfStore,
        shelfWindowController: shelfWindowController,
        importCoordinator: dropImportCoordinator,
        dragContext: onboardingDragContext
    )
    lazy var settingsWindowController = SettingsWindowController(settings: settingsStore,
                                                                         hotKeyMonitor: hotKeyMonitor,
                                                                         launchAtLoginController: launchAtLoginController,
                                                                         updateController: updateController,
                                                                         storageManagementController: storageManagementController,
                                                                         navigation: settingsNavigation,
                                                                         supportController: supportController,
                                                                         clipboardHistoryStore: clipboardHistoryStore)
    lazy var menuBarController = MenuBarController(
        isShelfExpanded: { [weak self] in
            self?.shelfPresentationCoordinator.isExpanded ?? false
        },
        recents: recentItemsService,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onReaddRecent: { [weak self] entry in
            self?.shelfImporter.readdRecent(entry)
        },
        onShowSettings: { [weak self] in
            self?.settingsWindowController.show()
        },
        onShowQuickStart: { [weak self] in
            self?.onboardingController.replay()
        },
        onOpenHelp: { [weak self] in
            self?.supportController.openHelp()
        },
        onReportIssue: { [weak self] in
            self?.supportController.reportIssue()
        },
        onCheckForUpdates: { [weak self] in
            self?.updateController.checkForUpdates()
        },
        onOpenManualUpdate: { [weak self] in
            self?.updateController.openManualDownloadPage()
        },
        onShowClipboardHistory: { [weak self] in
            self?.clipboardHistoryWindowController.show()
        },
        onSaveClipboardImage: { [weak self] in
            self?.shelfImporter.saveClipboardImageToShelf()
        }
    )

    /// S7: 全局快捷键监听（Carbon RegisterEventHotKey 为主、NSEvent 全局监听
    /// 为备；注册失败状态供 S8 设置页提示）。internal：Settings scene 注入
    /// 环境（registrationError 展示）用。
    /// UX3: 单击 = toggle；双击 = 保存剪贴板到 shelf（识别窗 ~0.3s，设置可关）。
    lazy var hotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.hotKeyShortcut,
        onPress: { [weak self] in
            self?.toggleShelfForKeyboard()
        },
        onDoublePress: { [weak self] in
            self?.shelfImporter.saveClipboardToShelf()
        }
    )
    lazy var clipboardHotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.clipboardHistoryShortcut, hotKeyIdentifier: 2,
        onPress: { [weak self] in self?.clipboardHistoryWindowController.show() },
        onDoublePress: {}
    )
    /// S7: 鼠标摇动触发（识别核心 ShakeDetector 为纯类型，见 Triggers/）。
    lazy var mouseShakeMonitor = MouseShakeMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        self?.toggleShelf()
    })
    /// UX2: 屏幕边缘触发（拖拽版）。仅「唤出」不「隐藏」：贴边的意图是取用
    /// shelf（通常紧接着要向该侧投放），再次贴边反而隐藏会产生往复开关的
    /// 挫败感；隐藏仍由快捷键/菜单与 UX1 拖空无落入自动收回承担。
    /// UX2 设计变更（用户确认）：纯悬停不再触发，仅拖拽中（按住左键）贴边
    /// 短停留唤出；custom 位置无贴附缘时暂停（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身（isEdgeTabBeingDragged）也是 leftMouseDragged，
    /// 会路过贴缘带 —— 抑制，避免重定位拉环时误唤出。
    lazy var edgeTriggerMonitor = EdgeTriggerMonitor(shouldSuppress: { [weak self] in
        guard let self else { return true }
        return self.appState.isShelfVisible
            || self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        guard let self, !self.appState.isShelfVisible else { return }
        // UX2: 拖拽贴边唤出也记入自动唤出会话（拖空无落入自动收回）。
        self.shelfPresentationCoordinator.showClassic(animated: true)
        self.dragAutoShowSession.markShownAutomatically()
    })
    /// UX1: 拖拽开始监听（按下 → 位移超阈值判定拖拽 → 抬起结束）。
    /// 同时承担 UX2 贴边唤出的会话记帐：只要任一拖拽驱动唤出路径可能
    /// 生效（immediate 或边缘触发可用）就保持注册。EdgeTab 起还供给
    /// `isDragInProgress` 可观察状态（拉环投放暗示），因此拉环启用时
    /// 同样保持注册（applyTriggerSettings）。
    /// EdgeTab: 拖动拉环本身被识别为拖拽是正常的，但不应唤出 shelf ——
    /// 经 isEdgeTabBeingDragged 抑制（拉环此时独占该手势）。
    lazy var dragStartMonitor = DragStartMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onDragStart: { [weak self] in
        self?.handleDragStart()
    }, onDragUpdate: { [weak self] point in
        self?.handleDragUpdate(at: point)
    }, onDragEnd: { [weak self] in
        self?.handleDragEnd()
    })
    /// UX1/2: 拖拽自动唤出会话裁决（纯逻辑状态机，见 Triggers/DragStartMonitor）。
    var dragAutoShowSession = DragAutoShowSession()
    private var islandDragWasActivated = false

    /// EdgeTab: 贴屏幕边缘的常驻拉环（单击展开 / 拖入接收 / 沿边拖动换位）。
    /// 拉环与 shelf 互斥（shelf 展开时拉环隐藏；shelf 的外缘隐形热区承担
    /// 同点位收起）。
    lazy var edgeTabController = EdgeTabController(
        appState: appState,
        settings: settingsStore,
        dropHandler: dropHandler,
        onDestinationEntered: { [weak self] in
            self?.dragAutoShowSession.destinationEntered(sequenceNumber: $0)
        },
        onDestinationEnded: { [weak self] sequence, accepted in
            guard let self else { return }
            if dragAutoShowSession.destinationEnded(sequenceNumber: sequence, accepted: accepted),
               appState.isShelfVisible {
                shelfWindowController.hideShelf(animated: true)
            }
        },
        dragStartMonitor: dragStartMonitor,
        onToggleShelf: { [weak self] in
            self?.shelfPresentationCoordinator.toggleClassic(animated: true)
        },
        onShowShelf: { [weak self] in
            self?.shelfPresentationCoordinator.showClassic(animated: true)
        },
        onPreviewSuppressed: { [weak self] in
            self?.shelfWindowController.suppressClassicHoverPreview()
        }
    )

    /// S10: 语言覆盖必须在最早阶段生效——`AppleLanguages` 决定进程后续加载的
    /// 本地化资源（Bundle 主语言在首个本地化查询时锁定），故放在
    /// willFinishLaunching（SwiftUI scene 与任何 UI 构建之前）。
    /// 设置页注明「重启后生效」：运行期切换只写偏好，下次启动由此应用。
    lazy var maintenance = LaunchMaintenance(
        shelfStore: shelfStore, persistence: persistence, initialShelfLoadResult: initialShelfLoadResult,
        managedMoveJournal: managedMoveJournal, pendingImportJournal: pendingImportJournal,
        tempFileService: tempFileService, bookmarkService: bookmarkService, shelfNotice: shelfNotice
    )
    private lazy var shelfImporter = ShelfImporter(
        shelfStore: shelfStore, dropImportCoordinator: dropImportCoordinator,
        appState: appState, shelfNotice: shelfNotice, bookmarkService: bookmarkService,
        shelfPresentationCoordinator: shelfPresentationCoordinator
    )

    func toggleShelf() {
        shelfPresentationCoordinator.toggle(animated: true)
    }

    private func toggleShelfForKeyboard() {
        shelfPresentationCoordinator.toggleForKeyboard(animated: true)
    }

    // MARK: - UX1/UX2 drag-driven appearance

    /// UX1: 拖拽确认（位移超阈值）。开启新会话记帐；用户显式选择
    /// `.immediate` 模式时
    /// shelf 不可见时立即唤出并打自动唤出标记（拖拽前已可见 = 用户手动
    /// 唤出，不标记、不动它）。`.edgeOnly` 只做记帐，唤出交给边缘触发。
    private func handleDragStart() {
        dragAutoShowSession.dragBegan()
        guard settingsStore.effectivePreferredShelfSurface == .classic else { return }
        guard settingsStore.classicShelfEnabled else { return }
        guard settingsStore.dragAutoAppearMode == .immediate else { return }
        guard !appState.isShelfVisible else { return }
        shelfPresentationCoordinator.showClassic(animated: true)
        dragAutoShowSession.markShownAutomatically()
    }

    private func handleDragUpdate(at point: CGPoint) {
        guard settingsStore.islandEnabled,
              settingsStore.islandShelfEnabled,
              settingsStore.islandDragApproachEnabled,
              settingsStore.dragAutoAppearMode != .off else { return }
        if shelfPresentationCoordinator.dragApproachedTop(at: point) {
            islandDragWasActivated = true
        }
    }

    /// UX1: 未投放时自动收回；成功拖入默认保持展开，可由设置关闭。
    /// 本地接收区的回调可能晚于 mouse-up；状态机等待真实完成事件。
    ///
    /// 任务二审查结论（拖拽中可见性不变式）：本路径不会「拖拽中误隐」——
    /// DragStartMonitor 在派发 onDragEnd 前已把 isDragInProgress 复位，
    /// 收回只发生在抬起之后；成功落入（含已派发的异步物化）经
    /// onImportHandled → noteImport 置位，并由设置决定是否保持展开。
    /// 空架自动隐藏（拖拽中唯一可能误隐的路径）已在 EmptyShelfAutoHideRule
    /// 内按 isDragInProgress 门控。
    private func handleDragEnd() {
        let imported = dragAutoShowSession.receivedImport
        let shouldHideClassic = dragAutoShowSession.dragEnded(
            keepShelfOpenAfterDrop: settingsStore.keepShelfOpenAfterDrop
        )
        if islandDragWasActivated {
            shelfPresentationCoordinator.dragEnded(imported: imported)
            islandDragWasActivated = false
        }
        guard shouldHideClassic, appState.isShelfVisible else { return }
        shelfPresentationCoordinator.hideClassic(animated: true)
    }

    // MARK: - Trigger wiring (S7)

    /// S7: 按当前设置启停触发监听（启动时与设置变更时调用）。各 monitor
    /// 内部对「配置未变」做了幂等保护，因此可响应任意 UserDefaults 变更
    /// 直接重应用，不会重复注册事件监听。
    ///
    /// UX1/2: 拖拽自动出现由 `dragAutoAppearMode` 单控 —— `.immediate`
    /// 由 DragStartMonitor 在拖拽确认时直接唤出；`.edgeOnly` 由
    /// EdgeTriggerMonitor（拖拽贴边短停留）唤出；`.off` 两者皆停。
    /// 边缘机制在 custom 位置无贴附缘时暂停。DragStartMonitor 还承担
    /// 自动唤出会话记帐（拖空无落入自动收回），因此任一唤出路径可用
    /// 时都要保持注册；EdgeTab 起还供给拉环投放暗示的 `isDragInProgress`
    /// 状态，拉环可用（edgeTabEnabled 且非 custom）时同样保持注册。
    func applyTriggerSettings() {
        hotKeyMonitor.updateShortcut(settingsStore.hotKeyShortcut)
        hotKeyMonitor.setDoublePressEnabled(settingsStore.hotKeyDoublePressSavesClipboard)
        hotKeyMonitor.setEnabled(settingsStore.hotKeyEnabled)
        clipboardHotKeyMonitor.updateShortcut(settingsStore.clipboardHistoryShortcut)
        clipboardHotKeyMonitor.setEnabled(settingsStore.clipboardHistoryShortcut != nil
            && (!settingsStore.hotKeyEnabled || settingsStore.clipboardHistoryShortcut != settingsStore.hotKeyShortcut))
        clipboardHistoryStore.shortcutRegistrationError = settingsStore.hotKeyEnabled
            && settingsStore.clipboardHistoryShortcut != nil
            && settingsStore.clipboardHistoryShortcut == settingsStore.hotKeyShortcut
            ? String(localized: "Choose a history shortcut different from the shelf shortcut.")
            : clipboardHotKeyMonitor.registrationError

        if settingsStore.shakeTriggerEnabled {
            mouseShakeMonitor.start(parameters: settingsStore.shakeSensitivity.shakeParameters)
        } else {
            mouseShakeMonitor.stop()
        }

        let classicActive = settingsStore.classicShelfEnabled
        let edgeActive = classicActive
            && settingsStore.dragAutoAppearMode == .edgeOnly
            && settingsStore.shelfPosition != .custom
        if edgeActive {
            edgeTriggerMonitor.start(
                side: settingsStore.shelfPosition,
                dwellTime: settingsStore.edgeTriggerSensitivity.edgeDwellTime,
                bandWidth: settingsStore.edgeTriggerSensitivity.edgeBandWidth
            )
        } else {
            edgeTriggerMonitor.stop()
        }

        // EdgeTab 拉环常驻（开启 && 非 custom 即在位，不再随 shelf 显隐），
        // monitor 注册与拉环在位同一判定 —— 拉环一在位就需要拖拽状态。
        let edgeTabActive = classicActive
            && settingsStore.edgeTabEnabled
            && settingsStore.shelfPosition != .custom
        let islandDragActive = settingsStore.islandEnabled
            && settingsStore.islandShelfEnabled
            && settingsStore.islandDragApproachEnabled
            && settingsStore.dragAutoAppearMode != .off
        let classicImmediateActive = settingsStore.effectivePreferredShelfSurface == .classic
            && settingsStore.dragAutoAppearMode == .immediate
        if classicImmediateActive
            || edgeActive || edgeTabActive || islandDragActive {
            dragStartMonitor.start()
        } else {
            dragStartMonitor.stop()
        }
    }

    func stopTriggers() {
        hotKeyMonitor.setEnabled(false)
        clipboardHotKeyMonitor.setEnabled(false)
        mouseShakeMonitor.stop()
        edgeTriggerMonitor.stop()
        dragStartMonitor.stop()
    }
}
