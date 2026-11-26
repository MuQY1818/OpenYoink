import AppKit
import OSLog
import SwiftUI

/// 负责 shelf 面板的显示/隐藏（滑入滑出 + 透明度组合动画）、
/// 基于鼠标所在屏幕的 frame 计算，以及屏幕参数变化时的重新布局。
/// S6 起同时承担：Quick Look 会话持有（`QuickLookCoordinator`）与卡片键盘
/// 事件分派（空格/Delete/Esc，经 `ShelfPanel.onKeyDown` 回调）。
///
/// 公开 API 约定（S7 触发器、S8 设置均通过这里驱动面板）：
/// - `toggleShelf(animated:)` / `showShelf(animated:)` / `hideShelf(animated:)`
/// - `isShelfVisible: Bool`（只读，实际状态存于 `AppState`）
@MainActor
final class ShelfWindowController: NSObject {
    private static let animationDuration: TimeInterval = 0.2
    var onClassicDestinationEntered: ((Int) -> Void)?
    var onClassicDestinationEnded: ((Int, Bool) -> Void)?
    var onClassicPresentationRequested: (() -> Void)?
    var onClassicShelfHandoffChanged: (() -> Void)?

    private let appState: AppState
    /// S8: shelf 位置/宽度/autoHide 等布局与行为设置的来源（原
    /// `static let shelfWidth` 占位常量已移除，宽度由此供给）。
    let settings: SettingsStore
    let clipboardHistoryStore: ClipboardHistoryStore
    /// Shelf 数据（S3 起注入 ShelfView 的 @Environment）。
    /// S4: DragContainerView（NSDraggingDestination 桥接）同样持有此 store。
    let store: ShelfStore
    /// UX6: 空架自动隐藏裁决状态（跨 items 变更保持上一轮数量基线）。
    private var emptyAutoHideRule = EmptyShelfAutoHideRule()
    private var isUserRemovalInProgress = false
    /// S4: 拖入分派（pasteboard → ShelfItem），供 DragContainerView 调用。
    let importCoordinator: DropImportCoordinator
    let bookmarkService: BookmarkService
    let notices: ShelfNoticeModel
    let transferStore: TransferStore
    /// S4: 拖入悬停高亮/插入位置状态，DragContainerView 驱动、ShelfView 渲染。
    private let classicDropTargetState = DropTargetState()
    private let islandDropTargetState = DropTargetState()
    /// C5/C6: 卡片网格几何（ShelfView 上报 frame；DragContainerView 拖入定位、
    /// ShelfView 框选命中共用）。
    private let classicGridGeometry = ShelfGridGeometry()
    private let islandGridGeometry = ShelfGridGeometry()
    /// Runtime focus/expanded-stack state shared with SwiftUI card rendering.
    let interaction = ShelfInteractionState()
    /// S5: 拖出总控（卡片 mouseDragged → NSDraggingSession；结束后按设置策略
    /// 移除/保留/询问（S8 .ask NSAlert）并记入最近历史；S8 起经
    /// onSuccessfulDrop 回调接 autoHide）。
    private let classicDragOutController: DragOutController
    private let islandDragOutController: DragOutController
    /// S6: 物化临时文件目录（注入 SwiftUI 环境，供卡片菜单的 text 项操作使用）。
    let tempFileService: TempFileService
    /// S6: Quick Look 会话（QLPreviewPanel 数据源/代理；空格/双击/右键入口
    /// 汇聚于此，随窗口控制器长期存活）。
    let quickLookCoordinator: QuickLookCoordinator
    /// v1.2: distinguishes external references from managed-copy loss and owns
    /// the safe user-driven recovery actions.
    let itemRecoveryController: ItemRecoveryController
    /// v1.3: shared non-destructive selection actions and the retained AppKit
    /// share-session lifecycle.
    let shelfActionRunner: ShelfActionRunner
    /// Batch-level VoiceOver announcements live for the controller lifetime so
    /// SwiftUI redraws cannot repeat already spoken events.
    let accessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()
    /// 任务二：拖拽进行中状态（`DragStartMonitor.isDragInProgress`），供给
    /// 空架自动隐藏的门控 —— 拖拽期间任何自动显隐不得收起已可见的 shelf。
    private let dragStartMonitor: DragStartMonitor
    /// Expanded Island's visible Settings control uses the app's retained,
    /// LSUIElement-safe settings window rather than SwiftUI's response-chain
    /// action, which can silently fail for a non-activating panel.
    let onOpenSettings: @MainActor () -> Void
    /// v1.4: the classic shelf and Island share one dependency graph and one
    /// ShelfStore, but each owns an independent panel and visibility state.
    private var classicHoverPreviewState = ClassicShelfHoverPreviewStateMachine()
    private var classicHoverExitTask: Task<Void, Never>?
    private var classicHoverGlobalMonitor: Any?
    private var classicHoverLocalMonitor: Any?
    private var isOpeningClassicHoverPreview = false
    /// 快速上手期间只暂停自动隐藏，不改写用户的 autoHide 设置。
    private var onboardingPresentationCount = 0
    private var quickActionLayoutTask: Task<Void, Never>?
    private var classicFrameTransition = ShelfFrameTransitionState()
    private var classicVisibilityTransition = ShelfVisibilityTransitionState()
    /// issue #10：侧边 shelf 从拉环长出 / 收回拉环的形变状态。
    let classicReveal = ShelfRevealState()
    /// 拉环 ↔ 面板形变进行中：期间不改窗口阴影与 frame（任意偏好写入都会
    /// 触发 applyPresentationSettings），结束后统一恢复。
    private var isClassicMorphing = false
    /// 形变期间被推迟的布局请求（数量/设置变化），形变结束后补做。
    private var isClassicLayoutDeferred = false
    /// 可见期间高度变化动画的代次；新请求或隐藏会让旧动画的收尾失效。
    private var classicResizeGeneration: UInt = 0
    /// 面板窗口与玻璃面之间的透明边距（ShelfView classic 分支的 `.padding(8)`）。
    private static let classicSurfaceInset: CGFloat = 8

    /// shelf 逻辑上占用的 frame。可见期间变矮时窗口不缩（见
    /// `resizeClassicSurface`），只有顶部玻璃面是 shelf，底部多出的部分
    /// 透明、不接收点击；悬停、命中与形变都以这里为准，而不是窗口 frame。
    private var classicLogicalFrame: NSRect {
        let frame = classicPanel.frame
        guard let surfaceHeight = classicReveal.surfaceHeight else { return frame }
        let height = min(frame.height, surfaceHeight + Self.classicSurfaceInset * 2)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// 窗口 frame 即将被直接改写：作废进行中的高度动画，玻璃面重新撑满窗口。
    private func resetClassicSurfaceHeight() {
        classicResizeGeneration &+= 1
        classicReveal.pinSurfaceHeight(nil)
    }

    struct OnboardingPresentationSnapshot: Equatable, Sendable {
        fileprivate let surface: SettingsStore.PreferredShelfSurface
        fileprivate let wasVisible: Bool
    }

    lazy var keyboardRouter = ShelfKeyboardRouter(
        settings: settings, store: store, interaction: interaction,
        favoriteFoldersStore: islandModules.favoriteFoldersStore,
        bookmarkService: bookmarkService, notices: notices, shelfActionRunner: shelfActionRunner,
        itemRecoveryController: itemRecoveryController, quickLookCoordinator: quickLookCoordinator,
        tempFileService: tempFileService,
        hideShelf: { [weak self] in self?.hideShelf(animated: $0) },
        collapseIsland: { [weak self] in self?.collapseIsland(animated: $0) },
        withUserRemoval: { [weak self] action in self?.withUserRemoval(action) ?? action() }
    )

    func withUserRemoval<Result>(_ action: () -> Result) -> Result {
        let previous = isUserRemovalInProgress
        isUserRemovalInProgress = true
        defer { isUserRemovalInProgress = previous }
        return action()
    }

    private lazy var classicPanel: ShelfPanel = makePanel(
        presentationStyle: .classic,
        dropTargetState: classicDropTargetState,
        gridGeometry: classicGridGeometry,
        dragOutController: classicDragOutController
    )

    let islandModules: IslandModules
    var islandActivityCoordinator: IslandActivityCoordinator { islandModules.islandActivityCoordinator }
    var favoriteFolderDropCoordinator: FavoriteFolderDropCoordinator { islandModules.favoriteFolderDropCoordinator }

    private lazy var islandSurface = IslandSurfaceController(
        panel: islandPanel, settings: settings, modules: islandModules,
        quickLookCoordinator: quickLookCoordinator
    )

    private lazy var islandPanel: ShelfPanel = makePanel(
        presentationStyle: .island,
        dropTargetState: islandDropTargetState,
        gridGeometry: islandGridGeometry,
        dragOutController: islandDragOutController
    )

    var isShelfVisible: Bool {
        appState.isShelfVisible
    }

    var isIslandExpanded: Bool {
        islandActivityCoordinator.surfaceState.isExpanded
    }

    var isPreferredShelfExpanded: Bool {
        switch effectivePreferredShelfSurface {
        case .classic: appState.isShelfVisible
        case .island: islandActivityCoordinator.surfaceState.isExpanded
        case nil: false
        }
    }

    init(appState: AppState,
         store: ShelfStore,
         importCoordinator: DropImportCoordinator,
         bookmarkService: BookmarkService,
         notices: ShelfNoticeModel,
         transferStore: TransferStore,
         islandModules: IslandModules,
         tempFileService: TempFileService,
         settings: SettingsStore,
         recents: RecentItemsService,
         deliveryCoordinator: DeliveryCoordinator,
         dragStartMonitor: DragStartMonitor,
         clipboardHistoryStore: ClipboardHistoryStore,
         onOpenSettings: @escaping @MainActor () -> Void = {},
         onOpenStorageRecovery: @escaping @MainActor () -> Void = {},
         tutorialTokenForItem: @escaping @MainActor (UUID) -> String? = { _ in nil }) {
        self.appState = appState
        self.store = store
        self.importCoordinator = importCoordinator
        self.bookmarkService = bookmarkService
        self.notices = notices
        self.transferStore = transferStore
        self.islandModules = islandModules
        self.tempFileService = tempFileService
        self.settings = settings
        self.clipboardHistoryStore = clipboardHistoryStore
        self.dragStartMonitor = dragStartMonitor
        self.onOpenSettings = onOpenSettings
        self.classicDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            onSourceDragEnded: {
                dragStartMonitor.finishDrag()
            },
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.islandDragOutController = DragOutController(
            store: store,
            settings: settings,
            recents: recents,
            bookmarkService: bookmarkService,
            deliveryCoordinator: deliveryCoordinator,
            onSourceDragEnded: {
                dragStartMonitor.finishDrag()
            },
            tutorialTokenForItem: tutorialTokenForItem
        )
        self.quickLookCoordinator = QuickLookCoordinator(
            store: store,
            bookmarkService: bookmarkService,
            tempFileService: tempFileService
        )
        self.itemRecoveryController = ItemRecoveryController(
            store: store,
            bookmarkService: bookmarkService,
            notices: notices,
            openStorageRecovery: onOpenStorageRecovery
        )
        self.shelfActionRunner = ShelfActionRunner(
            bookmarkService: bookmarkService,
            notices: notices
        )
        super.init()
        // UX5/UX6: 项目增删 → 紧凑高度动画过渡 + 空架自动隐藏裁决。
        store.onItemsDidChange = { [weak self] in
            self?.handleItemsDidChange()
        }
        store.onSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        interaction.onActionSelectionDidChange = { [weak self] in
            self?.handleQuickActionVisibilityDidChange()
        }
        transferStore.onVisibilityDidChange = { [weak self] in
            self?.handleActivityVisibilityDidChange()
        }
        // S8: autoHide —— 拖出成功（operation 非空）且设置开启时隐藏 shelf。
        // 回调在 DragSessionController.draggingSession(endedAt:) 里按
        // 「实际发生 drop」判定后触发；隐藏与否在此处按最新设置裁决。
        classicDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.hideShelf(animated: true)
        }
        islandDragOutController.onSuccessfulDrop = { [weak self] in
            guard let self,
                  self.onboardingPresentationCount == 0,
                  self.settings.autoHide else { return }
            self.collapseIsland(animated: true)
        }
        // S6: QL 面板关闭后让 ShelfPanel 重新成为 key（nonactivating：只接
        // 键盘焦点、不激活应用），空格/Delete/Esc 保持可用。闭包内访问 panel
        // 发生在 QL 关闭时，面板早已创建，不影响 lazy 语义。
        quickLookCoordinator.onPanelClosed = { [weak self] in
            guard let self,
                  self.appState.isShelfVisible
                    || self.islandActivityCoordinator.surfaceState.isExpanded else { return }
            if self.islandActivityCoordinator.surfaceState.isExpanded {
                self.islandPanel.makeKey()
            } else if self.classicPanel.isVisible {
                self.classicPanel.makeKey()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // S9: Space 切换后的在位校正（见 revalidateFrameAfterSpaceChange）。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // S8: 位置/宽度设置变更时动画过渡到新 frame（见 applyLayoutSettings）。
    }

    deinit {
        quickActionLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    func shutdown() {
        quickActionLayoutTask?.cancel()
        classicHoverExitTask?.cancel()
        stopClassicHoverPreviewMonitoring()
        islandSurface.shutdown()
    }

    func toggleShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated)
            }
        case .island:
            islandActivityCoordinator.toggle()
        case nil:
            break
        }
    }

    /// Global-hot-key entry point: showing the shelf also makes its
    /// nonactivating panel key so the user can continue entirely by keyboard.
    func toggleShelfForKeyboard(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                if classicHoverPreviewState.isPreview {
                    promoteClassicHoverPreview()
                    classicPanel.makeKey()
                } else {
                    hideShelf(animated: animated)
                }
            } else {
                showShelf(animated: animated, takeKeyboardFocus: true)
            }
        case .island:
            if islandActivityCoordinator.surfaceState.isExpanded {
                collapseIsland(animated: animated)
            } else {
                showIslandShelf(animated: animated, takeKeyboardFocus: true)
            }
        case nil:
            break
        }
    }

    func showPreferredShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        switch effectivePreferredShelfSurface {
        case .classic:
            showShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case .island:
            showIslandShelf(animated: animated, takeKeyboardFocus: takeKeyboardFocus)
        case nil:
            break
        }
    }

    func hidePreferredShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic: hideShelf(animated: animated)
        case .island: collapseIsland(animated: animated)
        case nil: break
        }
    }

    /// 从贴附缘滑入并淡入（贴左缘时自左侧滑入，贴右缘时自右侧滑入）。
    func showShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isOpeningClassicHoverPreview {
            performClassicHoverActions(
                classicHoverPreviewState.handle(.persistentInteraction)
            )
        }
        guard settings.classicShelfEnabled else { return }
        // Repeated show requests may promote a preview or request focus, but
        // must not put an already visible/sliding panel back offscreen.
        if appState.isShelfVisible {
            if takeKeyboardFocus, interaction.focusedItemID == nil {
                interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
            }
            applyClassicLayout(animated: animated)
            if takeKeyboardFocus { classicPanel.makeKey() }
            return
        }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        let generation = classicVisibilityTransition.request(visible: true)
        let wasOnscreen = classicPanel.isVisible
        appState.showShelf()
        let targetFrame = classicTargetFrame()
        _ = classicFrameTransition.request(targetFrame, currentFrame: classicLogicalFrame)
        guard animated else {
            endClassicMorph()
            classicReveal.showImmediately()
            classicPanel.hasShadow = classicWantsWindowShadow
            classicPanel.alphaValue = 1
            classicPanel.setFrame(targetFrame, display: false)
            presentClassicPanel()
            if takeKeyboardFocus { classicPanel.makeKey() }
            return
        }
        if let origin = classicRevealOrigin(for: targetFrame), let generation {
            growClassicShelf(from: origin, to: targetFrame, wasOnscreen: wasOnscreen,
                             generation: generation, takeKeyboardFocus: takeKeyboardFocus)
            return
        }
        endClassicMorph()
        classicReveal.showImmediately()
        classicPanel.hasShadow = classicWantsWindowShadow
        // A closing panel is still onscreen. Reverse from its current frame and
        // alpha instead of jumping back to the fully hidden starting position.
        if !wasOnscreen {
            classicPanel.alphaValue = 0
            classicPanel.setFrame(classicHiddenFrame(for: targetFrame), display: false)
        }
        presentClassicPanel()
        if takeKeyboardFocus { classicPanel.makeKey() }
        PanelFrameAnimation.animate(classicPanel, to: targetFrame, duration: Self.animationDuration,
                                    timing: CAMediaTimingFunction(name: .easeOut), alpha: 1)
    }

    // MARK: - Edge tab ↔ shelf morph (issue #10)

    /// 原生液态玻璃自带边缘光学；再叠窗口阴影会在面板外多出一圈深色描边，
    /// 且只能在形变结束后整块出现（issue #10）。其余材质没有玻璃边缘，
    /// 仍靠窗口阴影体现层次。
    private var classicWantsWindowShadow: Bool {
        !settings.appearance.usesNativeGlass(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    /// 拉环在玻璃面局部坐标中的矩形；custom 位置（无贴附缘）返回 nil，
    /// 显隐退回原有的滑入/淡入。
    private func classicRevealOrigin(for panelFrame: NSRect) -> CGRect? {
        let surface = panelFrame.insetBy(dx: Self.classicSurfaceInset, dy: Self.classicSurfaceInset)
        let visibleFrame = Self.screen(containing: CGPoint(x: panelFrame.midX, y: panelFrame.midY))
            .visibleFrame
        guard let tab = ShelfLayoutEngine.edgeTabFrame(position: settings.shelfPosition,
                                                       offset: CGFloat(settings.shelfEdgeOffset),
                                                       visibleFrame: visibleFrame) else { return nil }
        return ShelfLayoutEngine.revealOriginRect(surfaceFrame: surface, tabFrame: tab,
                                                  position: settings.shelfPosition,
                                                  windowInset: Self.classicSurfaceInset)
    }

    /// Orders the panel in front of whatever is on screen, including another
    /// app's full-screen Space. Re-asserting the collection behavior makes
    /// AppKit re-join the active Space; a plain `orderFront` from an inactive
    /// app can leave the panel behind on the Space it last appeared on.
    private func presentClassicPanel() {
        // `.moveToActiveSpace` forces the panel into the Space that is on
        // screen right now, which fixes the first reveal inside a brand-new
        // full-screen Space. It cannot be combined with `.canJoinAllSpaces`,
        // so the panel switches to all-spaces behavior right after ordering.
        classicPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        classicPanel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.classicPanel.collectionBehavior =
                    [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            }
        }
    }

    /// 窗口直接就位到目标 frame，只让 SwiftUI 玻璃面从拉环矩形弹性长出
    /// （窗口 frame 不参与动画 → 网格不在动画中重排）。
    private func growClassicShelf(from origin: CGRect, to targetFrame: NSRect, wasOnscreen: Bool,
                                  generation: UInt, takeKeyboardFocus: Bool) {
        // 形变期间窗口形状每帧都在变；AppKit 的窗口阴影只按某一帧计算，会残留
        // 成错位的轮廓。动画结束后再恢复并重算。
        isClassicMorphing = true
        classicPanel.hasShadow = false
        if !wasOnscreen {
            classicReveal.pinSurfaceHeight(nil)
            classicReveal.prepareCollapsed(at: origin)
        }
        classicReveal.capturesWholeSurface = dragStartMonitor.isDragInProgress
        // 悬停预览要跟手：用更快、不回弹的版本。
        let quick = isOpeningClassicHoverPreview
        classicPanel.alphaValue = 1
        if classicPanel.frame != targetFrame {
            resetClassicSurfaceHeight()
            classicPanel.setFrame(targetFrame, display: false)
        }
        presentClassicPanel()
        if takeKeyboardFocus { classicPanel.makeKey() }
        // 先让收拢态真正提交一帧，再在下一拍开始生长，避免两次状态合并成跳变。
        classicPanel.contentView?.layoutSubtreeIfNeeded()
        classicPanel.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.classicVisibilityTransition.isCurrent(generation, visible: true) else { return }
                self.classicReveal.expand(quick: quick)
                let settle = quick ? ShelfRevealState.quickExpandSettleDuration
                                   : ShelfRevealState.expandSettleDuration
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.classicVisibilityTransition.isCurrent(generation, visible: true)
                        else { return }
                        self.finishClassicGrow(generation: generation)
                    }
                }
            }
        }
    }

    private func finishClassicGrow(generation: UInt) {
        // 先撤掉拖放兜底覆盖层，等 SwiftUI 重绘后再按最终圆角形状计算阴影，
        // 否则阴影会按整块矩形算出来。
        let hadWholeSurfaceCapture = classicReveal.capturesWholeSurface
        classicReveal.capturesWholeSurface = false
        let restore = { [weak self] in
            guard let self,
                  self.classicVisibilityTransition.isCurrent(generation, visible: true) else { return }
            self.endClassicMorph()
            self.classicPanel.hasShadow = self.classicWantsWindowShadow
            self.classicPanel.invalidateShadow()
        }
        if hadWholeSurfaceCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { restore() }
            }
        } else {
            restore()
        }
    }

    /// 结束形变：补做形变期间被推迟的布局。
    private func endClassicMorph() {
        guard isClassicMorphing else { return }
        isClassicMorphing = false
        if isClassicLayoutDeferred {
            isClassicLayoutDeferred = false
            applyClassicLayout(animated: true)
        }
    }

    /// 内容先淡出，玻璃面收回拉环矩形，再由关闭流程交还边缘。
    private func foldClassicShelf(into origin: CGRect, generation: UInt) {
        isClassicMorphing = true
        classicPanel.hasShadow = false
        classicReveal.capturesWholeSurface = false
        classicReveal.collapse(to: origin) { [weak self] in
            self?.finishClassicHide(generation: generation)
        }
    }

    private func finishClassicHide(generation: UInt) {
        guard classicVisibilityTransition.isCurrent(generation, visible: false),
              appState.shelfPresentation == .closing else { return }
        // Retire the glass before the tab can be shown, with no independent
        // fade timer and no run-loop gap between the two window operations.
        classicPanel.orderOut(nil)
        isClassicLayoutDeferred = false
        isClassicMorphing = false
        appState.hideShelf()
        onClassicShelfHandoffChanged?()
    }

    func showIslandShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return }
        itemRecoveryController.refreshAll()
        interaction.normalize(for: store.items)
        if takeKeyboardFocus, interaction.focusedItemID == nil {
            interaction.focusedItemID = store.selectedItems.first?.id ?? store.items.first?.id
        }
        islandSurface.expand(takeKeyboardFocus: takeKeyboardFocus)
    }

    /// 快速上手获得一个显示租约：记录进入前可见性、暂停所有自动隐藏并显示
    /// shelf。租约结束时恢复原可见性，不写任何用户设置。
    func beginOnboardingPresentation() -> OnboardingPresentationSnapshot {
        let surface = effectivePreferredShelfSurface ?? .classic
        let wasVisible = surface == .classic
            ? appState.isShelfVisible
            : islandActivityCoordinator.surfaceState.isExpanded
        let snapshot = OnboardingPresentationSnapshot(surface: surface, wasVisible: wasVisible)
        onboardingPresentationCount += 1
        if !wasVisible {
            if surface == .island {
                showIslandShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            } else {
                showShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
        return snapshot
    }

    func endOnboardingPresentation(_ snapshot: OnboardingPresentationSnapshot) {
        onboardingPresentationCount = max(0, onboardingPresentationCount - 1)
        guard onboardingPresentationCount == 0, !snapshot.wasVisible else { return }
        if snapshot.surface == .island {
            collapseIsland(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        } else if appState.isShelfVisible {
            hideShelf(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }

    /// 引导面板布局使用。隐藏时返回当前设置对应的目标 frame，不要求先创建
    /// 或展示 NSPanel。
    var visibleOrTargetFrame: CGRect {
        if effectivePreferredShelfSurface == .island {
            return islandActivityCoordinator.surfaceState.isExpanded
                ? islandPanel.frame : islandSurface.islandTargetFrame()
        }
        return appState.isShelfVisible ? classicLogicalFrame : classicTargetFrame()
    }

    /// 向贴附缘滑出并淡出，结束后 orderOut。
    func hideShelf(animated: Bool = true) {
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        performClassicHoverActions(classicHoverPreviewState.handle(.shelfHidden))
        guard appState.isShelfVisible,
              let generation = classicVisibilityTransition.request(visible: false) else { return }
        stopClassicHoverPreviewMonitoring()
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = nil
        classicResizeGeneration &+= 1
        let visibleFrame = classicFrameTransition.targetFrame ?? classicLogicalFrame
        appState.beginShelfClose()
        onClassicShelfHandoffChanged?()
        classicFrameTransition.reset()
        // S6: shelf 隐藏时关掉 Quick Look 并释放会话资源（不恢复键盘焦点）。
        quickLookCoordinator.closeForShelfHide()
        let targetFrame = classicHiddenFrame(for: visibleFrame)
        guard animated else {
            finishClassicHide(generation: generation)
            classicReveal.showImmediately()
            classicPanel.hasShadow = classicWantsWindowShadow
            return
        }
        if let origin = classicRevealOrigin(for: classicLogicalFrame) {
            foldClassicShelf(into: origin, generation: generation)
            return
        }
        PanelFrameAnimation.animate(classicPanel, to: targetFrame, duration: Self.animationDuration,
                                    timing: CAMediaTimingFunction(name: .easeIn), alpha: 0) { [weak self] in
            // 隐藏期间若用户重新唤出，则不打断显示状态。
            MainActor.assumeIsolated {
                self?.finishClassicHide(generation: generation)
            }
        }
    }

    func collapseIsland(animated: Bool = true) {
        islandSurface.collapseIsland(animated: animated)
    }

    // MARK: - Classic shelf hover preview

    /// EdgeTabController forwards pointer changes here so the preview state is
    /// shared with the actual shelf window and all persistent interactions.
    func classicEdgeTabHoverChanged(_ hovering: Bool) {
        guard settings.classicShelfHoverRevealEnabled,
              settings.classicShelfEnabled,
              settings.edgeTabEnabled,
              settings.shelfPosition != .custom,
              !dragStartMonitor.isDragInProgress,
              !IgnoreListService.frontmostAppIsIgnored(
                in: settings.ignoredAppBundleIDs
              ) else {
            suppressClassicHoverPreview()
            return
        }
        let event: ClassicShelfHoverPreviewStateMachine.Event = hovering
            ? .tabEntered : .tabExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    func suppressClassicHoverPreview() {
        performClassicHoverActions(classicHoverPreviewState.handle(.suppress))
    }

    func promoteClassicHoverPreviewIfNeeded() {
        guard classicHoverPreviewState.isPreview else { return }
        promoteClassicHoverPreview()
    }

    private func promoteClassicHoverPreview() {
        performClassicHoverActions(
            classicHoverPreviewState.handle(.persistentInteraction)
        )
    }

    private func performClassicHoverActions(
        _ actions: [ClassicShelfHoverPreviewStateMachine.Action]
    ) {
        for action in actions {
            switch action {
            case .scheduleDwell:
                // `mouseEntered` already expresses the user's proximity
                // intent. Reveal in the same event turn; only mouse exit keeps
                // a grace period so crossing from the tab into the shelf does
                // not make the panel flicker.
                performClassicHoverActions(
                    classicHoverPreviewState.handle(.dwellElapsed)
                )
            case .cancelDwell:
                continue
            case .showPreview:
                guard !appState.isShelfVisible else { continue }
                isOpeningClassicHoverPreview = true
                showShelf(animated: true, takeKeyboardFocus: false)
                isOpeningClassicHoverPreview = false
                startClassicHoverPreviewMonitoring()
                updateClassicHoverPreviewPointer(at: NSEvent.mouseLocation)
            case .scheduleExit:
                guard classicHoverExitTask == nil else { continue }
                classicHoverExitTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, !Task.isCancelled else { return }
                    self.classicHoverExitTask = nil
                    self.performClassicHoverActions(
                        self.classicHoverPreviewState.handle(.exitElapsed)
                    )
                }
            case .cancelExit:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
            case .hidePreview:
                stopClassicHoverPreviewMonitoring()
                if appState.isShelfVisible { hideShelf(animated: true) }
            case .promoteToPersistent:
                classicHoverExitTask?.cancel()
                classicHoverExitTask = nil
                stopClassicHoverPreviewMonitoring()
            }
        }
    }

    private func startClassicHoverPreviewMonitoring() {
        guard classicHoverGlobalMonitor == nil, classicHoverLocalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged,
        ]
        classicHoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
        }
        classicHoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.handleClassicHoverPreviewEvent(event, at: point) }
            return event
        }
    }

    private func stopClassicHoverPreviewMonitoring() {
        if let classicHoverGlobalMonitor {
            NSEvent.removeMonitor(classicHoverGlobalMonitor)
            self.classicHoverGlobalMonitor = nil
        }
        if let classicHoverLocalMonitor {
            NSEvent.removeMonitor(classicHoverLocalMonitor)
            self.classicHoverLocalMonitor = nil
        }
    }

    private func handleClassicHoverPreviewEvent(_ event: NSEvent, at point: CGPoint) {
        guard classicHoverPreviewState.isPreview else { return }
        guard !IgnoreListService.frontmostAppIsIgnored(
            in: settings.ignoredAppBundleIDs
        ) else {
            suppressClassicHoverPreview()
            return
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged:
            if classicLogicalFrame.contains(point) { promoteClassicHoverPreview() }
        case .mouseMoved:
            updateClassicHoverPreviewPointer(at: point)
        default:
            break
        }
    }

    private func updateClassicHoverPreviewPointer(at point: CGPoint) {
        let event: ClassicShelfHoverPreviewStateMachine.Event = classicLogicalFrame
            .insetBy(dx: -2, dy: -2).contains(point) ? .shelfEntered : .shelfExited
        performClassicHoverActions(classicHoverPreviewState.handle(event))
    }

    private var effectivePreferredShelfSurface: SettingsStore.PreferredShelfSurface? {
        settings.effectivePreferredShelfSurface
    }

    // MARK: - Layout

    /// 位置与宽度由 SettingsStore 供给；纯计算收敛在 `ShelfLayoutEngine`（S9）。
    /// 左/右跟随鼠标所在屏幕（鼠标屏被拔掉回退主屏），贴设定缘；UX5 起高度
    /// 贴合内容（按 `store.items.count` 推算行数，上限可见高度 80%）；EdgeTab
    /// 起垂直位置按 `shelfEdgeOffset`（0 = 底缘、1 = 顶缘，默认 0.5 居中）；
    /// custom 用校验后的持久化 frame（首次/所在屏被拔掉时从目标屏
    /// 右缘默认 frame 起步）。
    private func classicTargetFrame() -> NSRect {
        ShelfLayoutEngine.targetFrame(
            position: settings.shelfPosition,
            width: settings.shelfWidth,
            itemCount: store.items.count,
            hasActivity: transferStore.hasVisibleActivity,
            hasQuickActions: hasVisibleQuickActions,
            hasSearchControls: true,
            mouseLocation: NSEvent.mouseLocation,
            screens: Self.screenGeometries(),
            persistedCustomFrame: settings.customShelfFrame,
            edgeOffset: CGFloat(settings.shelfEdgeOffset)
        )
    }

    private var hasVisibleQuickActions: Bool {
        guard !interaction.isSelecting else { return false }
        let items = ShelfActionSelectionResolver.explicitItems(
            topLevelItems: store.items,
            topLevelSelection: store.selection,
            expandedStackID: interaction.expandedStackID,
            childSelection: interaction.childSelection
        )
        return ShelfActionCatalog.hasAnyAction(for: items)
    }

    /// 隐藏态 frame：左/右向贴附缘方向平移一个面板宽度；custom 原位（淡出）。
    private func classicHiddenFrame(for frame: NSRect) -> NSRect {
        ShelfLayoutEngine.hiddenFrame(for: frame, position: settings.shelfPosition)
    }

    /// 当前屏幕几何快照（NSScreen → 纯值，供 ShelfLayoutEngine）。
    private static func screenGeometries() -> [ShelfLayoutEngine.ScreenGeometry] {
        NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    /// 包含指定点的屏幕（回退主屏）。S7 的 EdgeTriggerMonitor 与本类布局
    /// 共用「鼠标所在屏幕」判定，保证边缘触发的一侧与 shelf 出现的一侧一致。
    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

    /// S9: 插拔屏/改分辨率 → 可见即按新几何重算 frame（鼠标所在屏被拔掉时
    /// ShelfLayoutEngine 回退主屏；custom frame 落出所有屏幕则回退右缘默认）。
    /// 隐藏态无持久目标，show 时自会按最新几何计算，这里无需动作。
    @objc private func screenParametersDidChange(_ notification: Notification) {
        if appState.isShelfVisible {
            let target = classicTargetFrame()
            _ = classicFrameTransition.request(target, currentFrame: classicLogicalFrame)
            resetClassicSurfaceHeight()
            classicPanel.setFrame(target, display: true)
        }
        if settings.islandEnabled {
            islandSurface.scheduleIslandLayoutUpdate()
        }
    }

    /// S9: Space 切换后的在位校正。canJoinAllSpaces + stationary 让面板留在原
    /// 全局坐标、跟随出现在每个 Space，屏幕几何并未变化 —— 因此只校验当前
    /// frame（落出可见区域时瞬时夹回，无动画），不按鼠标重新跟随，避免切
    /// Space 时 shelf 漂到鼠标所在屏。
    ///
    /// 必须 nonisolated：通知按投递线程同步回调（同 userDefaultsDidChange）。
    @objc private nonisolated func activeSpaceDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.islandSurface.logIslandPresentation("active-space-changed")
            self.revalidateFrameAfterSpaceChange()
        }
    }

    private func revalidateFrameAfterSpaceChange() {
        if settings.islandEnabled {
            // A desktop/Space transition must not re-order an already visible
            // Island or truncate a pending collapse with an immediate resize.
            islandSurface.scheduleIslandLayoutUpdate()
        }
        guard appState.isShelfVisible else { return }
        // Validate the destination during a slide, not its offscreen start.
        let frame = classicFrameTransition.targetFrame ?? classicLogicalFrame
        let corrected = ShelfLayoutEngine.onscreenCorrection(for: frame,
                                                             screens: Self.screenGeometries())
            ?? classicTargetFrame()
        guard corrected != frame else { return }
        _ = classicFrameTransition.request(corrected, currentFrame: classicLogicalFrame)
        resetClassicSurfaceHeight()
        classicPanel.setFrame(corrected, display: true)
    }

    /// S8: 设置变更 → 可见时动画过渡到新 frame。任何 UserDefaults 写入都会
    /// 投递该通知，frame 未实际变化时直接返回，无关设置项不会触发布局动画。
    ///
    /// 必须 nonisolated：通知按投递线程同步回调，投递方可能是任意线程；
    /// 选择器方法若保留 MainActor 隔离会在投递线程上触发隔离断言
    /// （同 AppDelegate.userDefaultsDidChange 的说明）。
    private func applyClassicLayout(animated: Bool = true) {
        guard appState.isShelfVisible else { return }
        // 形变以当前窗口 frame 为画布；中途改 frame 会让拉环起点错位。
        guard !isClassicMorphing else {
            isClassicLayoutDeferred = true
            return
        }
        let current = classicLogicalFrame
        var target = classicTargetFrame()
        // 只是内容高度变了（选中出现操作栏、增删卡片）：顶边保持不动，否则
        // 标题和搜索框会随高度变化上下跳。
        let isHeightOnly = settings.shelfPosition != .custom
            && classicPanel.isVisible
            && target.width == current.width && target.minX == current.minX
        if isHeightOnly {
            let visible = Self.screen(containing: CGPoint(x: current.midX, y: current.midY)).visibleFrame
            target.origin.y = min(max(current.maxY - target.height, visible.minY),
                                  visible.maxY - target.height)
        }
        guard classicFrameTransition.request(target, currentFrame: current) else { return }
        guard target != current else { return }
        guard animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            resetClassicSurfaceHeight()
            classicPanel.setFrame(target, display: true)
            return
        }
        if isHeightOnly, current.maxY == target.maxY {
            resizeClassicSurface(to: target)
            return
        }
        resetClassicSurfaceHeight()
        PanelFrameAnimation.animate(classicPanel, to: target, duration: Self.animationDuration,
                                    timing: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /// 顶边不动的高度变化：玻璃与内容的高度交给 SwiftUI 逐帧动画，窗口
    /// 只在需要变高时瞬间扩高（多出的部分先透明），变矮时**不缩**。
    ///
    /// 不缩窗口是因为 WindowServer 对「顶边固定」的缩小（高度减小 + 原点
    /// 上移）并不保证原子：点过 Share 菜单之后尤其明显，新尺寸先生效、
    /// 原点晚几帧才跟上，整块 shelf 会往下掉一截再弹回。多出的透明区域
    /// 不接收点击，隐藏或下次改 frame 时自然收回。
    private func resizeClassicSurface(to target: NSRect) {
        classicResizeGeneration &+= 1
        let generation = classicResizeGeneration
        let inset = Self.classicSurfaceInset * 2
        let window = classicPanel.frame
        let shownHeight = classicReveal.surfaceHeight ?? (window.height - inset)
        let targetHeight = target.height - inset
        let needsTallerWindow = target.height > window.height
        if needsTallerWindow {
            classicReveal.pinSurfaceHeight(shownHeight)
            classicPanel.setFrame(target, display: true)
        } else if classicReveal.surfaceHeight == nil {
            classicReveal.pinSurfaceHeight(shownHeight)
        }
        let fillsWindow = needsTallerWindow || target.height == window.height
        classicReveal.animateSurfaceHeight(to: targetHeight) { [weak self] in
            guard let self, self.classicResizeGeneration == generation else { return }
            // 玻璃面恰好撑满窗口时解除锁定；否则保持锁定，底部维持透明。
            if fillsWindow { self.classicReveal.pinSurfaceHeight(nil) }
            if self.classicPanel.hasShadow { self.classicPanel.invalidateShadow() }
        }
    }

    /// UX5/UX6: items 变更（store.onItemsDidChange 钩子）统一处理：
    /// 1. UX5 紧凑高度 —— 可见时数量变化动画过渡到新目标 frame（custom
    ///    位置的目标 frame 不含内容高度，天然 no-op）；
    /// 2. Apply empty-shelf auto-hide unless a management removal or drag
    ///    currently owns the transition.
    private func handleItemsDidChange() {
        interaction.normalize(for: store.items)
        let shouldAutoHide = emptyAutoHideRule.evaluate(
            itemCount: store.items.count,
            isVisible: appState.isShelfVisible,
            isEnabled: settings.autoHideWhenEmpty && onboardingPresentationCount == 0,
            isDragInProgress: dragStartMonitor.isDragInProgress,
            isUserRemoval: isUserRemovalInProgress
        )
        if appState.isShelfVisible {
            applyClassicLayout()
        }
        // 空架隐藏放在高度动画之后裁决：两者同帧时隐藏优先（隐藏动画覆盖）。
        if shouldAutoHide {
            hideShelf(animated: true)
        }
    }

    /// ActivityStrip changes compact height but must not participate in the
    /// non-empty → empty auto-hide state machine.
    private func handleActivityVisibilityDidChange() {
        islandModules.transfersModuleRuntime.refresh()
        applyClassicLayout()
    }

    /// Explicit top-level or expanded-stack selection changes only affect the
    /// quick-action row. They do not enter the item persistence or empty-shelf
    /// auto-hide state machines.
    private func handleQuickActionVisibilityDidChange() {
        guard appState.isShelfVisible else { return }
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.applyQuickActionLayoutChange()
        }
    }

    private func applyQuickActionLayoutChange() {
        quickActionLayoutTask = nil
        applyClassicLayout()
    }

    // MARK: - Island presentation

    /// Applies two independent surface preferences over the same ShelfStore.
    /// Enabling or disabling one surface never changes the other's visibility
    /// or deletes shelf content.
    func applyPresentationSettings(animated: Bool = false) {
        classicPanel.allowsTopEdgeOverlap = false
        classicPanel.level = .floating
        // 形变中途按半成品形状算出的阴影会残留成错位轮廓；形变结束时会恢复。
        if !isClassicMorphing { classicPanel.hasShadow = classicWantsWindowShadow }
        if settings.classicShelfEnabled {
            if appState.isShelfVisible {
                applyClassicLayout(animated: animated)
                if !classicPanel.isVisible {
                    classicPanel.alphaValue = 1
                    presentClassicPanel()
                }
            }
        } else {
            _ = classicVisibilityTransition.request(visible: false)
            classicFrameTransition.reset()
            classicPanel.orderOut(nil)
            isClassicLayoutDeferred = false
            isClassicMorphing = false
            appState.hideShelf()
        }

        islandSurface.applySettings()
    }

    func islandDragApproachedTop(at point: CGPoint) -> Bool {
        islandSurface.islandDragApproachedTop(at: point)
    }

    func islandDragEnded(imported: Bool) {
        islandSurface.islandDragEnded(imported: imported)
    }
}
