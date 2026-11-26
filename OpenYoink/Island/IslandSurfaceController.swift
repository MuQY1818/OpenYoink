import AppKit
import OSLog
import QuartzCore

@MainActor
final class IslandSurfaceController: NSObject {
    private let settings: SettingsStore
    private let modules: IslandModules
    private let quickLookCoordinator: QuickLookCoordinator
    private let islandLogger = Log.make(category: "IslandPresentation")
    let panel: ShelfPanel
    private var islandActivityCoordinator: IslandActivityCoordinator { modules.islandActivityCoordinator }
    private var islandModuleRegistry: IslandModuleRegistry { modules.islandModuleRegistry }
    private var islandModuleContainer: IslandModuleContainer { modules.islandModuleContainer }
    private var nowPlayingModuleStore: NowPlayingModuleStore { modules.nowPlayingModuleStore }

    private struct PointerEvent: Sendable {
        let mouse: MouseEventSample
        let eventNumber: Int
        let windowNumber: Int

        nonisolated init(_ event: NSEvent) {
            mouse = MouseEventSample(event)
            eventNumber = event.eventNumber
            windowNumber = event.windowNumber
        }
    }

    private lazy var pointerMonitor = EventMonitor(
        matching: [.leftMouseDown, .mouseMoved],
        capture: { PointerEvent($0) },
        handler: { [weak self] in self?.handleIslandEvent($0) }
    )
    private var islandHoverTask: Task<Void, Never>?
    private var islandLayoutTask: Task<Void, Never>?
    /// Floating Island idle dot / hidden mode.
    private var isFloatingIslandRevealed = false
    private var floatingConcealTask: Task<Void, Never>?
    private var floatingShrinkTask: Task<Void, Never>?
    /// Keeps the panel at pill size while SwiftUI shrinks the pill into the
    /// dot; shrinking the window first would clip that animation.
    private var isFloatingShrinkPending = false
    private var islandFrameTransition = ShelfFrameTransitionState()
    init(panel: ShelfPanel, settings: SettingsStore, modules: IslandModules,
         quickLookCoordinator: QuickLookCoordinator) {
        self.panel = panel
        self.settings = settings
        self.modules = modules
        self.quickLookCoordinator = quickLookCoordinator
        super.init()
        let islandActivityCoordinator = modules.islandActivityCoordinator
        islandActivityCoordinator.onSurfaceStateWillChange = { [weak self] oldState, newState in
            self?.prepareIslandPanelTransition(from: oldState, to: newState)
        }
        islandActivityCoordinator.onStateDidChange = { [weak self] in
            self?.scheduleIslandLayoutUpdate()
        }
        islandActivityCoordinator.onSurfaceAnimationCompleted = { [weak self] in
            guard let self else { return }
            self.logIslandPresentation("surface-animation-completed")
            self.scheduleIslandLayoutUpdate()
        }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(islandWindowStateDidChange(_:)),
                name: name, object: panel
            )
        }
    }

    deinit {
        islandHoverTask?.cancel()
        islandLayoutTask?.cancel()
        floatingConcealTask?.cancel()
        floatingShrinkTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func shutdown() {
        modules.favoriteFolderDropCoordinator.cancelCopy()
        islandHoverTask?.cancel()
        islandLayoutTask?.cancel()
        floatingConcealTask?.cancel()
        floatingShrinkTask?.cancel()
        stopIslandModules()
        stopIslandEventMonitoring()
    }

    func expand(takeKeyboardFocus: Bool) {
        islandActivityCoordinator.show(module: .shelf)
        panel.orderFront(nil)
        if takeKeyboardFocus { panel.makeKey() }
    }

    func applySettings() {
        islandModuleRegistry.apply(settings: settings)
        if settings.islandEnabled {
            // A regular floating panel is constrained below the menu bar by AppKit.
            // Island chrome must occupy the camera-housing band itself, matching
            // status-item z-order while staying below screen-saver windows so drag
            // sessions keep reaching it.
            panel.allowsTopEdgeOverlap = true
            let level = NSWindow.Level(
                rawValue: NSWindow.Level.statusBar.rawValue + 8
            )
            if panel.level != level { panel.level = level }
            panel.hasShadow = false
            startEnabledIslandModules()
            pointerMonitor.start()
            if islandActivityCoordinator.surfaceState == .hidden {
                islandActivityCoordinator.setSurfaceState(.compact)
            }
            if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule),
               let fallback = islandModuleRegistry.enabledDescriptors.first?.id {
                islandActivityCoordinator.selectedModule = fallback
            }
            if panel.isVisible {
                scheduleIslandLayoutUpdate()
            } else {
                islandLayoutTask?.cancel()
                islandLayoutTask = nil
                islandFrameTransition.reset()
                let target = islandTargetFrame()
                _ = islandFrameTransition.request(target, currentFrame: panel.frame)
                panel.alphaValue = 1
                panel.setFrame(target, display: true)
                panel.orderFront(nil)
            }
        } else {
            islandLayoutTask?.cancel()
            islandLayoutTask = nil
            islandFrameTransition.reset()
            stopIslandModules()
            stopIslandEventMonitoring()
            islandActivityCoordinator.hide()
            panel.orderOut(nil)
        }
    }

    func collapseIsland(animated: Bool = true) {
        guard settings.islandEnabled else { return }
        quickLookCoordinator.closeForShelfHide()
        logIslandPresentation("collapse-request")
        islandActivityCoordinator.collapse()
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            islandLayoutTask?.cancel()
            islandLayoutTask = nil
            let target = islandTargetFrame()
            _ = islandFrameTransition.request(target, currentFrame: panel.frame)
            if panel.frame != target {
                panel.setFrame(target, display: true)
            }
        }
    }

    func islandTargetFrame() -> NSRect {
        let layout = islandLayout()
        islandActivityCoordinator.currentLayout = layout
        refreshFloatingPresentation(layout: layout)
        if islandActivityCoordinator.surfaceState.isExpanded { return layout.expandedFrame }
        return compactWindowFrame(for: layout)
    }

    /// The collapsed panel: the pill, or just the dot's hit area when the
    /// floating Island is idle. Hidden mode keeps the dot-sized panel but
    /// draws nothing and lets clicks through.
    private func compactWindowFrame(for layout: IslandGeometryResolver.Layout) -> NSRect {
        switch islandActivityCoordinator.floatingPresentation {
        case .capsule:
            return layout.compactFrame
        case .dot, .hidden:
            return isFloatingShrinkPending ? layout.compactFrame : layout.floatingDotFrame
        }
    }

    /// Where a click or hover counts as touching the collapsed Island.
    private func interactiveCompactFrame(for layout: IslandGeometryResolver.Layout) -> NSRect {
        switch islandActivityCoordinator.floatingPresentation {
        case .capsule: return layout.compactFrame
        case .dot: return layout.floatingDotFrame
        case .hidden: return .null
        }
    }

    private func refreshFloatingPresentation(layout: IslandGeometryResolver.Layout) {
        let coordinator = islandActivityCoordinator
        let urgent = (coordinator.primaryActivity()?.priority ?? .shelfSummary) >= .powerChange
        if layout.hasPhysicalNotch || settings.islandFloatingIdleStyle == .capsule {
            isFloatingIslandRevealed = false
            floatingConcealTask?.cancel()
            floatingConcealTask = nil
        }
        let next = IslandFloatingPresentation.resolve(
            style: settings.islandFloatingIdleStyle,
            hasPhysicalNotch: layout.hasPhysicalNotch,
            isExpanded: coordinator.surfaceState != .compact,
            hasUrgentActivity: urgent,
            isRevealed: isFloatingIslandRevealed
        )
        let current = coordinator.floatingPresentation
        guard next != current else { return }
        coordinator.floatingPresentation = next
        panel.ignoresMouseEvents = next == .hidden
        if next == .capsule {
            floatingShrinkTask?.cancel()
            floatingShrinkTask = nil
            isFloatingShrinkPending = false
            // Grow the panel before SwiftUI draws the pill into it.
            if coordinator.surfaceState == .compact, panel.frame != layout.compactFrame {
                islandLayoutTask?.cancel()
                islandLayoutTask = nil
                islandFrameTransition.reset()
                _ = islandFrameTransition.request(layout.compactFrame, currentFrame: panel.frame)
                panel.setFrame(layout.compactFrame, display: true)
            }
        } else if current == .capsule,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isFloatingShrinkPending = true
            floatingShrinkTask?.cancel()
            floatingShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard let self, !Task.isCancelled else { return }
                self.floatingShrinkTask = nil
                self.isFloatingShrinkPending = false
                self.scheduleIslandLayoutUpdate()
            }
        }
    }

    /// Dot / hidden mode: the pill comes back when the pointer reaches the
    /// dot or the top edge of the screen above it, and leaves again shortly
    /// after the pointer moves away.
    private func updateFloatingReveal(at point: CGPoint, layout: IslandGeometryResolver.Layout) {
        guard !layout.hasPhysicalNotch,
              settings.islandFloatingIdleStyle != .capsule,
              islandActivityCoordinator.surfaceState == .compact else { return }
        if !isFloatingIslandRevealed {
            let touchesDot = islandActivityCoordinator.floatingPresentation == .dot
                && layout.floatingDotFrame.insetBy(dx: -4, dy: -4).contains(point)
            guard touchesDot || layout.floatingEdgeRevealFrame.contains(point) else { return }
            isFloatingIslandRevealed = true
            refreshFloatingPresentation(layout: layout)
        } else if layout.floatingKeepRevealedFrame.contains(point) {
            floatingConcealTask?.cancel()
            floatingConcealTask = nil
        } else if floatingConcealTask == nil {
            floatingConcealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.floatingConcealTask = nil
                self.isFloatingIslandRevealed = false
                self.scheduleIslandLayoutUpdate()
            }
        }
    }

    private func prepareIslandPanelTransition(
        from oldState: IslandSurfaceState,
        to newState: IslandSurfaceState
    ) {
        islandLogger.notice("surface-transition \(String(describing: oldState), privacy: .public) -> \(String(describing: newState), privacy: .public) id=\(self.islandActivityCoordinator.surfaceTransitionID)")
        guard settings.islandEnabled,
              !oldState.isExpanded,
              newState.isExpanded else { return }
        // A selected-module change can already have queued a compact layout
        // pass. Cancel it so no stale frame is applied between preparation and
        // the actual surface-state mutation.
        islandLayoutTask?.cancel()
        islandLayoutTask = nil

        let layout = islandLayout()
        islandActivityCoordinator.currentLayout = layout
        // Give SwiftUI a fixed, top-centred canvas before the visible morph
        // starts. The compact surface remains centred inside this transparent
        // canvas, while its mask grows to the expanded size. Animating the
        // AppKit window and SwiftUI hierarchy at the same time made hosting-view
        // relayout appear as a lateral jump from the right.
        _ = islandFrameTransition.request(layout.expandedFrame, currentFrame: panel.frame)
        if panel.frame != layout.expandedFrame {
            panel.setFrame(layout.expandedFrame, display: true)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func islandLayout(at point: CGPoint = NSEvent.mouseLocation)
        -> IslandGeometryResolver.Layout {
        if let screen = IslandScreenCatalog.selectedScreen(
            for: settings.islandDisplayTarget,
            pointerPoint: point
        ) {
            return IslandGeometryResolver.resolve(
                screen: IslandScreenCatalog.geometry(for: screen)
            )
        }
        return IslandGeometryResolver.resolve(screen: .init(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        ))
    }

    func islandDragApproachedTop(at point: CGPoint) -> Bool {
        guard settings.islandEnabled,
              settings.islandShelfEnabled,
              settings.islandDragApproachEnabled else { return false }
        let layout = islandLayout(at: point)
        guard layout.activationFrame.contains(point) else { return false }
        islandActivityCoordinator.currentLayout = layout
        if !islandActivityCoordinator.surfaceState.isExpanded {
            islandActivityCoordinator.beginDrag()
            return true
        }
        return false
    }

    func islandDragEnded(imported: Bool) {
        guard settings.islandEnabled, settings.islandShelfEnabled else { return }
        islandActivityCoordinator.endDrag(imported: imported)
    }

    private func startEnabledIslandModules() {
        if !islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            islandActivityCoordinator.selectedModule =
                islandModuleRegistry.enabledDescriptors.first?.id ?? .transfers
        }
        islandModuleContainer.apply(
            configuration: settings.islandModuleConfiguration,
            isActive: true
        )
    }

    private func stopIslandModules() {
        islandModuleContainer.stopAll()
    }

    func scheduleIslandLayoutUpdate() {
        guard settings.islandEnabled else { return }
        let target = islandTargetFrame()
        // SwiftUI owns the visible fold. A wall-clock sleep can expire before
        // that animation has even started during Show Desktop. Keep the host
        // canvas intact until its actual completion, including interrupted folds.
        if !islandActivityCoordinator.surfaceState.isExpanded,
           islandActivityCoordinator.isSurfaceTransitionPending,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return
        }
        // Activity samples, defaults notifications and desktop/Space changes
        // can all arrive during the same collapse. Compare destinations before
        // cancelling: identical requests must not restart its deadline.
        if islandLayoutTask == nil { islandFrameTransition.reset() }
        guard islandFrameTransition.request(target, currentFrame: panel.frame) else { return }
        islandLayoutTask?.cancel()
        islandLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            defer {
                // A cancelled task may have been replaced by a newer request.
                if !Task.isCancelled {
                    self.islandLayoutTask = nil
                    self.islandFrameTransition.reset()
                }
            }

            guard target != self.panel.frame else { return }

            if !self.islandActivityCoordinator.surfaceState.isExpanded {
                guard !self.islandActivityCoordinator.isSurfaceTransitionPending
                        || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                self.panel.setFrame(target, display: true)
                self.logIslandPresentation("compact-frame-applied")
                return
            }
            await self.animateIsland(to: target)
        }
    }

    private func animateIsland(to target: NSRect) async {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            return
        }
        let isExpanding = target.height > panel.frame.height
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let duration = isExpanding ? IslandMotion.expandWindowDuration : IslandMotion.collapseWindowDuration
            let timing = isExpanding
                ? CAMediaTimingFunction(controlPoints: 0.22, 0.78, 0.18, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.20, 1.0)
            PanelFrameAnimation.animate(panel, to: target, duration: duration, timing: timing) {
                continuation.resume()
            }
        }
    }

    private func stopIslandEventMonitoring() {
        pointerMonitor.stop()
        islandHoverTask?.cancel()
        islandHoverTask = nil
        islandActivityCoordinator.setPointerHovering(false)
    }

    private func handleIslandEvent(_ event: PointerEvent) {
        let point = event.mouse.location
        guard settings.islandEnabled else { return }
        switch event.mouse.type {
        case .leftMouseDown:
            if !islandActivityCoordinator.surfaceState.isExpanded {
                let layout = islandLayout(at: point)
                guard interactiveCompactFrame(for: layout).contains(point) else { return }
                // The right music wing owns a direct play/pause action. Let
                // its SwiftUI button consume the click instead of expanding.
                guard !isCompactMediaTransportHit(point, layout: layout) else { return }
                islandActivityCoordinator.currentLayout = layout
                islandActivityCoordinator.show(module: effectiveIslandOpenModule)
                return
            }
            guard islandActivityCoordinator.surfaceState == .expanded,
                  !panel.frame.contains(point) else { return }
            islandLogger.notice("outside-click event=\(event.eventNumber) window=\(event.windowNumber)")
            collapseIsland(animated: true)
        case .mouseMoved:
            let layout = islandLayout(at: point)
            if !islandActivityCoordinator.surfaceState.isExpanded {
                if islandActivityCoordinator.currentLayout?.compactFrame != layout.compactFrame {
                    scheduleIslandLayoutUpdate()
                }
                updateFloatingReveal(at: point, layout: layout)
            }
            let interactiveFrame = interactiveCompactFrame(for: layout)
            islandActivityCoordinator.setPointerHovering(
                !islandActivityCoordinator.surfaceState.isExpanded
                    && interactiveFrame.contains(point)
            )
            guard settings.islandHoverRevealEnabled,
                  islandActivityCoordinator.canRevealOnHover,
                  !islandActivityCoordinator.surfaceState.isExpanded else {
                islandHoverTask?.cancel()
                islandHoverTask = nil
                return
            }
            guard islandActivityCoordinator.floatingPresentation == .capsule,
                  interactiveFrame.insetBy(dx: -4, dy: -4).contains(point) else {
                islandHoverTask?.cancel()
                islandHoverTask = nil
                return
            }
            guard islandHoverTask == nil else { return }
            islandHoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.islandHoverTask = nil
                self.islandActivityCoordinator.show(module: self.effectiveIslandOpenModule)
            }
        default:
            break
        }
    }

    /// Low-frequency lifecycle diagnostics only; never includes clipboard data,
    /// file names, screen contents or a continuous pointer trace.
    func logIslandPresentation(_ reason: String) {
        let state = String(describing: islandActivityCoordinator.surfaceState)
        let frame = NSStringFromRect(panel.frame)
        islandLogger.notice("\(reason, privacy: .public) state=\(state, privacy: .public) id=\(self.islandActivityCoordinator.surfaceTransitionID) pending=\(self.islandActivityCoordinator.isSurfaceTransitionPending) frame=\(frame, privacy: .public) visible=\(self.panel.isVisible) occluded=\(!self.panel.occlusionState.contains(.visible)) key=\(self.panel.isKeyWindow)")
    }

    @objc private nonisolated func islandWindowStateDidChange(_ notification: Notification) {
        let reason = notification.name.rawValue
        Task { @MainActor [weak self] in
            self?.logIslandPresentation(reason)
        }
    }

    private var effectiveIslandOpenModule: IslandModuleID {
        if let activity = islandActivityCoordinator.primaryActivity(),
           islandModuleRegistry.isEnabled(activity.moduleID) {
            return activity.moduleID
        }
        if islandModuleRegistry.isEnabled(islandActivityCoordinator.selectedModule) {
            return islandActivityCoordinator.selectedModule
        }
        return islandModuleRegistry.enabledDescriptors.first?.id ?? .transfers
    }

    private func isCompactMediaTransportHit(
        _ point: CGPoint,
        layout: IslandGeometryResolver.Layout
    ) -> Bool {
        guard islandActivityCoordinator.primaryActivity()?.moduleID == .media,
              nowPlayingModuleStore.snapshot != nil,
              nowPlayingModuleStore.supportsTransportControls else { return false }
        let controlWidth = layout.hasPhysicalNotch
            ? IslandGeometryResolver.compactWingWidth
            : 48
        let frame = CGRect(x: layout.compactFrame.maxX - controlWidth,
                           y: layout.compactFrame.minY,
                           width: controlWidth,
                           height: layout.compactFrame.height)
        return frame.contains(point)
    }
}
