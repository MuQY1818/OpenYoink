import AppKit
import OSLog
import SwiftUI

///
/// - `toggleShelf(animated:)` / `showShelf(animated:)` / `hideShelf(animated:)`
@MainActor
final class ShelfWindowController: NSObject {
    private static let animationDuration: TimeInterval = 0.2
    var onClassicDestinationEntered: ((Int) -> Void)?
    var onClassicDestinationEnded: ((Int, Bool) -> Void)?
    var onClassicPresentationRequested: (() -> Void)?
    var onClassicShelfHandoffChanged: (() -> Void)?

    private let appState: AppState

    let settings: SettingsStore
    let clipboardHistoryStore: ClipboardHistoryStore

    let store: ShelfStore
    private var emptyAutoHideRule = EmptyShelfAutoHideRule()
    private var isUserRemovalInProgress = false
    let dropHandler: ShelfDropHandler
    let bookmarkService: BookmarkService
    let notices: ShelfNoticeModel
    let transferStore: TransferStore
    private let classicDropTargetState = DropTargetState()
    private let islandDropTargetState = DropTargetState()

    private let classicGridGeometry = ShelfGridGeometry()
    private let islandGridGeometry = ShelfGridGeometry()
    /// Runtime focus/expanded-stack state shared with SwiftUI card rendering.
    let interaction = ShelfInteractionState()

    private let classicDragOutController: DragOutController
    private let islandDragOutController: DragOutController
    let tempFileService: TempFileService

    let quickLookCoordinator: QuickLookCoordinator
    /// distinguishes external references from managed-copy loss and owns
    /// the safe user-driven recovery actions.
    let itemRecoveryController: ItemRecoveryController
    /// shared non-destructive selection actions and the retained AppKit
    /// share-session lifecycle.
    let shelfActionRunner: ShelfActionRunner
    /// Batch-level VoiceOver announcements live for the controller lifetime so
    /// SwiftUI redraws cannot repeat already spoken events.
    let accessibilityAnnouncementCenter: AccessibilityAnnouncementCenter

    private let dragStartMonitor: DragStartMonitor
    /// Expanded Island's visible Settings control uses the app's retained,
    /// LSUIElement-safe settings window rather than SwiftUI's response-chain
    /// action, which can silently fail for a non-activating panel.
    let onOpenSettings: @MainActor () -> Void
    /// the classic shelf and Island share one dependency graph and one
    /// ShelfStore, but each owns an independent panel and visibility state.
    /// Onboarding pauses every automatic hide without touching `autoHide`.
    private var onboardingPresentationCount = 0
    private var quickActionLayoutTask: Task<Void, Never>?
    private var classicFrameTransition = ShelfFrameTransitionState()
    private var classicVisibilityTransition = ShelfVisibilityTransitionState()
    let classicReveal = ShelfRevealState()

    private var isClassicMorphing = false
    private var isClassicLayoutDeferred = false
    private var classicResizeGeneration: UInt = 0
    private static let classicSurfaceInset: CGFloat = 8

    private var classicLogicalFrame: NSRect {
        let frame = classicPanel.frame
        guard let surfaceHeight = classicReveal.surfaceHeight else { return frame }
        let height = min(frame.height, surfaceHeight + Self.classicSurfaceInset * 2)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

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

    var isPreferredShelfExpanded: Bool {
        switch effectivePreferredShelfSurface {
        case .classic: appState.isShelfVisible
        case .island: islandActivityCoordinator.surfaceState.isExpanded
        case nil: false
        }
    }

    init(appState: AppState,
         store: ShelfStore,
         dropHandler: ShelfDropHandler,
         bookmarkService: BookmarkService,
         notices: ShelfNoticeModel,
         transferStore: TransferStore,
         islandModules: IslandModules,
         tempFileService: TempFileService,
         settings: SettingsStore,
         classicDragOutController: DragOutController,
         islandDragOutController: DragOutController,
         quickLookCoordinator: QuickLookCoordinator,
         itemRecoveryController: ItemRecoveryController,
         shelfActionRunner: ShelfActionRunner,
         accessibilityAnnouncementCenter: AccessibilityAnnouncementCenter,
         dragStartMonitor: DragStartMonitor,
         clipboardHistoryStore: ClipboardHistoryStore,
         onOpenSettings: @escaping @MainActor () -> Void) {
        self.appState = appState
        self.store = store
        self.dropHandler = dropHandler
        self.bookmarkService = bookmarkService
        self.notices = notices
        self.transferStore = transferStore
        self.islandModules = islandModules
        self.tempFileService = tempFileService
        self.settings = settings
        self.clipboardHistoryStore = clipboardHistoryStore
        self.dragStartMonitor = dragStartMonitor
        self.onOpenSettings = onOpenSettings
        self.classicDragOutController = classicDragOutController
        self.islandDragOutController = islandDragOutController
        self.quickLookCoordinator = quickLookCoordinator
        self.itemRecoveryController = itemRecoveryController
        self.shelfActionRunner = shelfActionRunner
        self.accessibilityAnnouncementCenter = accessibilityAnnouncementCenter
        super.init()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        quickActionLayoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Public API

    func shutdown() {
        quickActionLayoutTask?.cancel()
        islandSurface.shutdown()
    }

    func toggleShelf(animated: Bool = true) {
        switch effectivePreferredShelfSurface {
        case .classic:
            if appState.isShelfVisible {
                hideShelf(animated: animated)
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
                hideShelf(animated: animated)
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

    func showShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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

    // MARK: - Edge tab ↔ shelf morph

    private var classicWantsWindowShadow: Bool {
        !settings.appearance.usesNativeGlass(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

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

    private func growClassicShelf(from origin: CGRect, to targetFrame: NSRect, wasOnscreen: Bool,
                                  generation: UInt, takeKeyboardFocus: Bool) {

        isClassicMorphing = true
        classicPanel.hasShadow = false
        if !wasOnscreen {
            classicReveal.pinSurfaceHeight(nil)
            classicReveal.prepareCollapsed(at: origin)
        }
        classicReveal.capturesWholeSurface = dragStartMonitor.isDragInProgress
        classicPanel.alphaValue = 1
        if classicPanel.frame != targetFrame {
            resetClassicSurfaceHeight()
            classicPanel.setFrame(targetFrame, display: false)
        }
        presentClassicPanel()
        if takeKeyboardFocus { classicPanel.makeKey() }
        classicPanel.contentView?.layoutSubtreeIfNeeded()
        classicPanel.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.classicVisibilityTransition.isCurrent(generation, visible: true) else { return }
                self.classicReveal.expand()
                let settle = ShelfRevealState.expandSettleDuration
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

    private func endClassicMorph() {
        guard isClassicMorphing else { return }
        isClassicMorphing = false
        if isClassicLayoutDeferred {
            isClassicLayoutDeferred = false
            applyClassicLayout(animated: true)
        }
    }

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

    var visibleOrTargetFrame: CGRect {
        if effectivePreferredShelfSurface == .island {
            return islandActivityCoordinator.surfaceState.isExpanded
                ? islandPanel.frame : islandSurface.islandTargetFrame()
        }
        return appState.isShelfVisible ? classicLogicalFrame : classicTargetFrame()
    }

    /// Slides out towards the attached edge while fading out.
    func hideShelf(animated: Bool = true) {
        onClassicPresentationRequested?()
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard appState.isShelfVisible,
              let generation = classicVisibilityTransition.request(visible: false) else { return }
        quickActionLayoutTask?.cancel()
        quickActionLayoutTask = nil
        classicResizeGeneration &+= 1
        let visibleFrame = classicFrameTransition.targetFrame ?? classicLogicalFrame
        appState.beginShelfClose()
        onClassicShelfHandoffChanged?()
        classicFrameTransition.reset()
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
            MainActor.assumeIsolated {
                self?.finishClassicHide(generation: generation)
            }
        }
    }

    func collapseIsland(animated: Bool = true) {
        islandSurface.collapseIsland(animated: animated)
    }

    private var effectivePreferredShelfSurface: SettingsStore.PreferredShelfSurface? {
        settings.effectivePreferredShelfSurface
    }

    // MARK: - Layout

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

    private func classicHiddenFrame(for frame: NSRect) -> NSRect {
        ShelfLayoutEngine.hiddenFrame(for: frame, position: settings.shelfPosition)
    }

    private static func screenGeometries() -> [ShelfLayoutEngine.ScreenGeometry] {
        NSScreen.screens.map { .init(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.screens[0]
    }

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

    private func applyClassicLayout(animated: Bool = true) {
        guard appState.isShelfVisible else { return }
        guard !isClassicMorphing else {
            isClassicLayoutDeferred = true
            return
        }
        let current = classicLogicalFrame
        var target = classicTargetFrame()

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
            if fillsWindow { self.classicReveal.pinSurfaceHeight(nil) }
            if self.classicPanel.hasShadow { self.classicPanel.invalidateShadow() }
        }
    }

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
