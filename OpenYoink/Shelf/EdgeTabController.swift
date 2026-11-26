import AppKit

@MainActor
final class EdgeTabController: NSObject {
    private static let fadeDuration: TimeInterval = 0.18
    private static let handOffFadeDuration: TimeInterval = 0.08
    private static let emphasisDuration: TimeInterval = 0.15
    /// Frame transitions, in step with the shelf's show/hide.
    private static let moveDuration: TimeInterval = 0.2

    private let appState: AppState
    private let settings: SettingsStore
    private let dropHandler: ShelfDropHandler
    private let onDestinationEntered: (Int) -> Void
    private let onDestinationEnded: (Int, Bool) -> Void
    private let dragStartMonitor: DragStartMonitor
    private let onToggleShelf: @MainActor () -> Void
    private let onShowShelf: @MainActor () -> Void

    private var isTabBeingDragged = false

    /// A file drag with importable content hovers over the tab.
    private var isDropTargeted = false
    /// The emphasis currently applied, to skip repeated animations.
    private var isEmphasized = false
    private var visibilityTransition = ShelfVisibilityTransitionState()

    private lazy var panel: EdgeTabPanel = {
        let panel = EdgeTabPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                             height: ShelfLayoutEngine.edgeTabHeight)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = tabView
        panel.setAccessibilityLabel(String(localized: "Show Shelf"))
        return panel
    }()

    private lazy var tabView: EdgeTabView = {
        let view = EdgeTabView(frame: NSRect(origin: .zero,
                                             size: NSSize(width: ShelfLayoutEngine.edgeTabWidth,
                                                          height: ShelfLayoutEngine.edgeTabHeight)))
        view.position = settings.shelfPosition
        view.onClick = { [weak self] in
            self?.onToggleShelf()
        }
        view.onReposition = { [weak self] offset, position in
            self?.finishReposition(offset: offset, position: position)
        }
        view.onRepositionStateChanged = { [weak self] active in
            guard let self else { return }
            self.isTabBeingDragged = active
            self.appState.setEdgeTabBeingDragged(active)
            // Only set the flag: the drag monitor's isDragInProgress resets one run
            // loop after mouse-up, and re-evaluating now would flash the drop hint.
            // The drag-end observation does the final evaluation.
        }
        view.onDropTargetChanged = { [weak self] targeted in
            guard let self, self.isDropTargeted != targeted else { return }
            self.isDropTargeted = targeted
            self.updateEmphasis(animated: true)
        }
        view.acceptsDrop = { [weak self] sender in
            self?.dropHandler.accepts(sender) ?? false
        }
        view.onDestinationEntered = { [weak self] in self?.onDestinationEntered($0) }
        view.onDestinationEnded = { [weak self] in self?.onDestinationEnded($0, $1) }
        view.onDrop = { [weak self] sender in
            guard let self, dropHandler.performDrop(sender) else { return false }
            onShowShelf()
            return true
        }
        return view
    }()

    init(appState: AppState,
         settings: SettingsStore,
         dropHandler: ShelfDropHandler,
         onDestinationEntered: @escaping (Int) -> Void,
         onDestinationEnded: @escaping (Int, Bool) -> Void,
         dragStartMonitor: DragStartMonitor,
         onToggleShelf: @escaping @MainActor () -> Void,
         onShowShelf: @escaping @MainActor () -> Void) {
        self.appState = appState
        self.settings = settings
        self.dropHandler = dropHandler
        self.onDestinationEntered = onDestinationEntered
        self.onDestinationEnded = onDestinationEnded
        self.dragStartMonitor = dragStartMonitor
        self.onToggleShelf = onToggleShelf
        self.onShowShelf = onShowShelf
        super.init()
        beginObservation()

        // Displays or resolution changed: recompute from the new geometry.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Initial evaluation: the shelf starts hidden, so the tab appears without animation.
        applyState(animated: false)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility state machine

    /// Enabled, attached to an edge (not custom), and the shelf hidden: tab and
    /// shelf never show together.
    private var shouldBeVisible: Bool {
        settings.classicShelfEnabled
            && settings.edgeTabEnabled
            && settings.shelfPosition != .custom
            && appState.canShowEdgeTab
    }

    /// At close start, retire any in-flight tab fade from a just-opened Shelf.
    /// At close end, show the replacement only after the Shelf is ordered out.
    func synchronizeShelfHandoff() {
        applyState(animated: false)
    }

    /// Re-evaluates after visibility, settings, screen or drag changes.
    func applyState(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        tabView.configure(appearance: settings.appearance,
                          iconVisible: settings.edgeTabIconVisible,
                          iconSize: settings.edgeTabIconSize)
        // Keep the view's side in sync (corners, flip reference), except during
        // a drag, which may have flipped live without persisting yet.
        if !isTabBeingDragged {
            tabView.position = settings.shelfPosition
        }
        guard shouldBeVisible else {
            // Hiding clears the emphasis, so the next show starts from the resting
            // frame and never reappears with a stale enlarged one.
            if isEmphasized {
                isEmphasized = false
                tabView.isEmphasized = false
            }
            hideTab(animated: animated)
            return
        }
        let visibilityChanged = visibilityTransition.request(visible: true) != nil
        let target = currentTargetFrame()
        if panel.isVisible {
            // Reversing a fade-out keeps the window ordered in. Restore alpha
            // as well as its layout; isVisible alone does not imply alpha == 1.
            if visibilityChanged || !animated { restoreTabAlpha(animated: animated) }
            // While dragged the gesture owns the frame. Resting-position changes
            // (settings, screens) animate.
            if !isTabBeingDragged, panel.frame != target {
                if animated {
                    PanelFrameAnimation.animate(panel, to: target, duration: Self.moveDuration,
                                                timing: CAMediaTimingFunction(name: .easeInEaseOut))
                } else {
                    panel.setFrame(target, display: true)
                }
            }
        } else {
            showTab(target, animated: animated)
        }
        updateEmphasis(animated: animated)
    }

    private func showTab(_ frame: NSRect, animated: Bool) {
        panel.setFrame(frame, display: false)
        guard animated else {
            panel.alphaValue = 1
            presentTabPanel()
            return
        }
        panel.alphaValue = 0
        presentTabPanel()
        restoreTabAlpha(animated: true)
    }

    /// Same Space handling as the shelf panel: re-assert the collection behavior
    /// and order front regardless of activation so the tab also joins another
    /// app's full-screen Space instead of staying on its previous one.
    private func presentTabPanel() {
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
    }

    private func restoreTabAlpha(animated: Bool) {
        guard animated else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideTab(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let generation = visibilityTransition.request(visible: false)
        guard panel.isVisible else { return }
        guard animated else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        guard let generation else { return }
        NSAnimationContext.runAnimationGroup({ context in
            // The shelf's glass starts exactly on the tab and covers it, so the
            // tab only needs a brief hand-off fade.
            context.duration = appState.isShelfVisible ? Self.handOffFadeDuration : Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Don't interrupt if the tab became due again while fading out.
            MainActor.assumeIsolated {
                guard let self,
                      self.visibilityTransition.isCurrent(generation, visible: false),
                      !self.shouldBeVisible else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Layout

    /// Same rule as the shelf: the pointer's screen, else the main one.
    private func targetVisibleFrame() -> CGRect {
        ShelfWindowController.screen(containing: NSEvent.mouseLocation).visibleFrame
    }

    /// The resting frame (a custom position only gets here if the state is
    /// broken; fall back to the origin).
    private func baseFrame() -> NSRect {
        return ShelfLayoutEngine.edgeTabFrame(position: settings.shelfPosition,
                                              offset: CGFloat(settings.shelfEdgeOffset),
                                              visibleFrame: targetVisibleFrame())
            ?? NSRect(x: 0, y: 0,
                      width: ShelfLayoutEngine.edgeTabWidth,
                      height: ShelfLayoutEngine.edgeTabHeight)
    }

    /// The enlarged frame while emphasized.
    private func currentTargetFrame() -> NSRect {
        let base = baseFrame()
        guard isEmphasized else { return base }
        return ShelfLayoutEngine.edgeTabEmphasisFrame(from: base,
                                                      position: settings.shelfPosition,
                                                      visibleFrame: targetVisibleFrame())
    }

    // MARK: - Emphasis (drag affordance / drop hover)

    /// Emphasized while a drop hovers, or while any drag other than the tab's
    /// own is in progress. Animates between resting and slightly enlarged.
    private func updateEmphasis(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let emphasized = panel.isVisible
            && (isDropTargeted || (dragStartMonitor.isDragInProgress && !isTabBeingDragged))
        guard emphasized != isEmphasized else { return }
        isEmphasized = emphasized
        tabView.isEmphasized = emphasized
        let target = currentTargetFrame()
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        PanelFrameAnimation.animate(panel, to: target, duration: Self.emphasisDuration,
                                    timing: CAMediaTimingFunction(name: .easeOut))
    }

    // MARK: - Gesture results

    /// After a drag (≥ threshold): persist offset and side. The store's change
    /// notification re-lays out to a frame equal to where the gesture ended, so
    /// nothing jumps.
    private func finishReposition(offset: CGFloat, position: SettingsStore.ShelfPosition) {
        settings.shelfEdgeOffset = Double(offset)
        if settings.shelfPosition != position {
            settings.shelfPosition = position
        }
    }

    // MARK: - Observation

    /// Tracks shelf visibility and drag progress. `withObservationTracking`
    /// fires once, so it re-registers after every change; its `onChange` is a
    /// nonisolated @Sendable closure that hops back to the main actor.
    /// `applyState` reads current values, so coalesced changes are safe.
    private func beginObservation() {
        withObservationTracking {
            _ = appState.shelfPresentation
            _ = dragStartMonitor.isDragInProgress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyState(animated: true)
                self.beginObservation()
            }
        }
    }

    @objc private nonisolated func screenParametersDidChange(_ notification: Notification) {
        Task { @MainActor in
            self.applyState(animated: true)
        }
    }
}

/// inner stroke and a small tray symbol. It handles:
/// 1. its own mouse gesture (not `performDrag`: movement is constrained to
///    the edge and may flip sides): down records the origin, dragged slides
///    along the edge, up under 4 pt is a click, otherwise offset and side
///    are reported;
/// 2. drops (registers `PasteboardTypes.dragInTypes`), forwarded to the
///    controller;
/// 3. the emphasized look, driven by the controller.
@MainActor
final class EdgeTabView: NSView {
    /// Below this distance (points) mouse-up is a click.
    static let clickThreshold: CGFloat = 4
    static let cornerRadius: CGFloat = 8

    /// The attached side, synced by the controller and updated live while
    /// flipping; sets the corner and stroke direction.
    var position: SettingsStore.ShelfPosition = .right {
        didSet {
            guard oldValue != position else { return }
            updateCornering()
        }
    }

    /// Accent stroke and light fill, with a smooth transition.
    var isEmphasized = false {
        didSet {
            guard oldValue != isEmphasized else { return }
            applyEmphasisAppearance(
                animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        }
    }

    /// Mouse-up within `clickThreshold`.
    var onClick: (@MainActor () -> Void)?
    /// After a drag: the latest offset and side (possibly flipped).
    var onReposition: (@MainActor (CGFloat, SettingsStore.ShelfPosition) -> Void)?
    /// A repositioning drag started or ended.
    var onRepositionStateChanged: (@MainActor (Bool) -> Void)?
    var onDropTargetChanged: (@MainActor (Bool) -> Void)?
    var onDrop: (@MainActor (NSDraggingInfo) -> Bool)?
    var acceptsDrop: (@MainActor (NSDraggingInfo) -> Bool)?
    var onDestinationEntered: ((Int) -> Void)?
    var onDestinationEnded: ((Int, Bool) -> Void)?

    private let vibrancyView = NSVisualEffectView()
    private var nativeGlassView: NSView?
    private let solidView = NSView()
    private let tintLayer = CALayer()
    private let iconView = NSImageView()
    private let strokeLayer = CAShapeLayer()
    private var shelfAppearance = ShelfAppearance.default
    private var hasConfiguredAppearance = false
    private var iconSize = SettingsStore.defaultEdgeTabIconSize
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?

    // State of one press.
    private var isRepositioning = false
    private var dragMoved = false
    private var dragStartCursor: CGPoint = .zero
    private var dragStartCenterY: CGFloat = 0
    private var pendingOffset: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the entire handle hit-testable even with a fully clear material
        // and hidden icon. Only the decoration changes with appearance settings.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor

        vibrancyView.material = .hudWindow
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        vibrancyView.layer?.cornerRadius = Self.cornerRadius
        vibrancyView.layer?.masksToBounds = true
        vibrancyView.setAccessibilityElement(false)
        vibrancyView.setAccessibilityHidden(true)
        addSubview(vibrancyView)
        solidView.wantsLayer = true
        solidView.setAccessibilityElement(false)
        solidView.setAccessibilityHidden(true)
        addSubview(solidView)
        if #available(macOS 26.0, *) {
            let glass = EdgeTabGlassView()
            glass.contentView = NSView()
            glass.cornerRadius = Self.cornerRadius
            glass.style = .regular
            glass.setAccessibilityElement(false)
            glass.setAccessibilityHidden(true)
            nativeGlassView = glass
            addSubview(glass)
        }
        tintLayer.cornerRadius = Self.cornerRadius
        layer?.addSublayer(tintLayer)

        iconView.image = NSImage(
            systemSymbolName: "tray.and.arrow.down",
            accessibilityDescription: String(localized: "Show Shelf")
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // The containing EdgeTabView is the actual button and already exposes
        // a localized "Show Shelf" label. Keep the decorative symbol out of
        // the accessibility tree so audits and VoiceOver do not encounter a
        // second, unlabeled element for the same control.
        iconView.setAccessibilityElement(false)
        iconView.setAccessibilityHidden(true)
        addSubview(iconView)

        // Inner stroke and emphasis fill: only the inward corners are rounded, inset 0.5.
        strokeLayer.lineWidth = 1
        strokeLayer.zPosition = 1
        layer?.addSublayer(strokeLayer)

        registerForDraggedTypes(PasteboardTypes.dragInTypes)

        setAccessibilityRole(.button)
        // The tab only shows while the shelf is hidden, so a click shows it.
        setAccessibilityLabel(String(localized: "Show Shelf"))

        updateCornering()
        configure(appearance: .default, iconVisible: true,
                  iconSize: SettingsStore.defaultEdgeTabIconSize)
        applyEmphasisAppearance(animated: false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private nonisolated func accessibilityOptionsDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.updateMaterial()
            self?.applyEmphasisAppearance(animated: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EdgeTabView is created programmatically")
    }

    override func layout() {
        super.layout()
        if vibrancyView.frame != bounds { vibrancyView.frame = bounds }
        // Put the outer rounded corners beyond the screen edge instead of
        // clipping the system effect's own edge optics with a layer mask.
        let glassFrame = NSRect(x: position == .left ? -Self.cornerRadius : 0,
                                y: 0, width: bounds.width + Self.cornerRadius,
                                height: bounds.height)
        if nativeGlassView?.frame != glassFrame { nativeGlassView?.frame = glassFrame }
        if solidView.frame != bounds { solidView.frame = bounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        strokeLayer.frame = bounds
        updateStrokePath()
        CATransaction.commit()
        let iconFrame = ShelfLayoutEngine.edgeTabIconFrame(in: bounds, size: iconSize)
        iconView.frame = iconView.superview?.convert(iconFrame, from: self) ?? iconFrame
    }

    func configure(appearance: ShelfAppearance, iconVisible: Bool, iconSize: Double) {
        let iconSize = SettingsStore.normalizedEdgeTabIconSize(iconSize)
        guard !hasConfiguredAppearance || shelfAppearance != appearance || iconView.isHidden == iconVisible
                || self.iconSize != iconSize else { return }
        hasConfiguredAppearance = true
        shelfAppearance = appearance
        self.iconSize = iconSize
        iconView.isHidden = !iconVisible
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(self.iconSize), weight: .regular
        )
        needsLayout = true
        updateMaterial()
        applyEmphasisAppearance(animated: false)
    }

    private func updateMaterial() {
        let appearance = shelfAppearance
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency || appearance.material == .solid
        let nativeGlass = appearance.usesNativeGlass(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        ) && nativeGlassView != nil
        vibrancyView.isHidden = opaque || nativeGlass || appearance.material == .clear
        nativeGlassView?.isHidden = !nativeGlass
        solidView.isHidden = !opaque && appearance.material != .clear
        tintLayer.isHidden = nativeGlass
        if #available(macOS 26.0, *), let glass = nativeGlassView as? NSGlassEffectView {
            glass.tintColor = appearance.nativeGlassTint
            let iconContainer = nativeGlass ? glass.contentView : self
            if let iconContainer, iconView.superview !== iconContainer {
                iconContainer.addSubview(iconView)
                needsLayout = true
            }
        }
        let theme: NSAppearance? = switch appearance.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if self.appearance?.name != theme?.name { self.appearance = theme }
        vibrancyView.material = appearance.material == .frosted ? .popover : .hudWindow
        let opacity = appearance.surfaceOpacity(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
        vibrancyView.alphaValue = opacity
        nativeGlassView?.alphaValue = opacity
        solidView.alphaValue = opacity
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solidView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            tintLayer.backgroundColor = appearance.tint.nsColor.withAlphaComponent(
                appearance.tintOpacity(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
            ).cgColor
        }
        // interactive glass inflates past the tab's window on press
        // and gets clipped into a hard outline. Hover/press feedback is drawn
        // by `applyEmphasisAppearance` instead.
        if #available(macOS 27.0, *), let glass = nativeGlassView as? NSGlassEffectView,
           glass.effectIsInteractive {
            glass.effectIsInteractive = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solidView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        applyEmphasisAppearance(animated: false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Decorative native material views must never intercept tab gestures.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyEmphasisAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyEmphasisAppearance(animated: true)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Mouse gesture (click / reposition / flip)

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartCursor = NSEvent.mouseLocation
        dragStartCenterY = window.frame.midY
        dragMoved = false
        isRepositioning = true
        applyEmphasisAppearance(animated: true)
        onRepositionStateChanged?(true)
    }

    /// y follows the drag (start center + Δy, clamped through the offset); x
    /// stays on the attached edge, flipping live past the midline.
    override func mouseDragged(with event: NSEvent) {
        guard isRepositioning, let window else { return }
        let cursor = NSEvent.mouseLocation
        if !dragMoved {
            let displacement = hypot(cursor.x - dragStartCursor.x, cursor.y - dragStartCursor.y)
            guard displacement >= Self.clickThreshold else { return }
            dragMoved = true
        }
        let screen = ShelfWindowController.screen(containing: cursor)
        if ShelfLayoutEngine.shouldFlipSide(position: position,
                                            cursorLocation: cursor,
                                            screenFrame: screen.frame) {
            position = position == .left ? .right : .left
        }
        let centerY = dragStartCenterY + (cursor.y - dragStartCursor.y)
        let offset = ShelfLayoutEngine.edgeTabOffset(forCenterY: centerY,
                                                     visibleFrame: screen.visibleFrame)
        pendingOffset = offset
        if let frame = ShelfLayoutEngine.edgeTabFrame(position: position, offset: offset,
                                                      visibleFrame: screen.visibleFrame) {
            window.setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isRepositioning else { return }
        isRepositioning = false
        applyEmphasisAppearance(animated: true)
        onRepositionStateChanged?(false)
        if dragMoved {
            dragMoved = false
            onReposition?(pendingOffset, position)
        } else {
            onClick?()
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop?(sender) == true else { return [] }
        onDestinationEntered?(sender.draggingSequenceNumber)
        onDropTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop?(sender) == true else { return [] }
        onDestinationEntered?(sender.draggingSequenceNumber)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let accepted = onDrop?(sender) ?? false
        onDestinationEnded?(sender.draggingSequenceNumber, accepted)
        return accepted
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDestinationEnded?(sender.draggingSequenceNumber, false)
        onDropTargetChanged?(false)
    }

    // MARK: - Appearance

    /// Corners face inwards: a right-edge tab rounds its left corners, a
    /// left-edge tab its right ones (symmetric, so the layer's flip doesn't matter).
    private func updateCornering() {
        let corners: CACornerMask = position == .left
            ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        vibrancyView.layer?.maskedCorners = corners
        solidView.layer?.cornerRadius = Self.cornerRadius
        solidView.layer?.maskedCorners = corners
        solidView.layer?.masksToBounds = true
        tintLayer.maskedCorners = corners
        needsLayout = true
        updateStrokePath()
    }

    private func updateStrokePath() {
        let rect = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 0.5, dy: 0.5)
        strokeLayer.path = Self.innerRoundedPath(in: rect,
                                                 radius: Self.cornerRadius - 0.5,
                                                 position: position)
    }

    private func applyEmphasisAppearance(animated: Bool) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let interacting = isPointerInside || isRepositioning
        let nativeGlass = shelfAppearance.usesNativeGlass(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let stroke: CGColor = isEmphasized
                ? NSColor.controlAccentColor.cgColor
                : NSColor.labelColor.withAlphaComponent(nativeGlass ? 0 : (interacting ? 0.24 : 0.10)).cgColor
            let fill: CGColor = isEmphasized
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : NSColor.labelColor.withAlphaComponent(isRepositioning ? (nativeGlass ? 0.08 : 0.10)
                                                         : (interacting ? (nativeGlass ? 0.04 : 0.05) : 0)).cgColor
            // An explicit duration so the color change animates implicitly.
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(animated ? 0.15 : 0)
            strokeLayer.strokeColor = stroke
            strokeLayer.fillColor = fill
            CATransaction.commit()
        }
    }

    /// Rounds only the inward corners (square on the edge side). Vertically
    /// symmetric, so correct in y-up and y-down space.
    private static func innerRoundedPath(in rect: CGRect,
                                         radius: CGFloat,
                                         position: SettingsStore.ShelfPosition) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let path = CGMutablePath()
        switch position {
        case .right:
            // Inward is left: round the top-left and bottom-left corners.
            path.move(to: CGPoint(x: maxX, y: minY))
            path.addLine(to: CGPoint(x: maxX, y: maxY))
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
            path.addArc(center: CGPoint(x: minX + r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: .pi, clockwise: false)
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addArc(center: CGPoint(x: minX + r, y: minY + r), radius: r,
                        startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
            path.closeSubpath()
        case .left:
            // Inward is right: round the top-right and bottom-right corners.
            path.move(to: CGPoint(x: minX, y: minY))
            path.addLine(to: CGPoint(x: minX, y: maxY))
            path.addLine(to: CGPoint(x: maxX - r, y: maxY))
            path.addArc(center: CGPoint(x: maxX - r, y: maxY - r), radius: r,
                        startAngle: .pi / 2, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: maxX, y: minY + r))
            path.addArc(center: CGPoint(x: maxX - r, y: minY + r), radius: r,
                        startAngle: 0, endAngle: .pi * 1.5, clockwise: true)
            path.closeSubpath()
        case .custom:
            // No tab here; a fully rounded rectangle as a fallback (never reached).
            path.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r,
                                transform: nil))
        }
        return path
    }
}

@available(macOS 26.0, *)
private final class EdgeTabGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
