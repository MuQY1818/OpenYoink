import AppKit

/// Optional destination override for module-specific drops. When active it
/// owns the complete drop decision, so a rejected file cannot silently fall
/// through into the shared ShelfStore behind another module's UI.
@MainActor
struct DragContainerDropOverride {
    let isActive: @MainActor () -> Bool
    let canHandle: @MainActor (DragContainerDropContext) -> Bool
    let perform: @MainActor (DragContainerDropContext) -> Bool
    var reset: @MainActor () -> Void = {}
}

@MainActor
struct DragContainerDropContext {
    let pasteboard: NSPasteboard
    let location: CGPoint
    let isInternal: Bool
    let internalItems: [ShelfItem]?
}

/// Drop hover state, driven by `DragContainerView` and rendered by
/// `ShelfView` (highlight, insertion marker, copy/move hint).
@MainActor
@Observable
final class DropTargetState {
    /// A drag is hovering over the shelf and can be accepted.
    var isTargeted = false
    /// Insert before the card at this index; `items.count` means after the last.
    var insertionIndex: Int?

    var mode: DropInMode = .copy
    /// Internal Shelf-card drags reorder existing items instead of importing.
    var isReordering = false

    func reset() {
        isTargeted = false
        insertionIndex = nil
        mode = .copy
        isReordering = false
    }
}

/// - Internal Shelf-card drags reorder existing items without importing;
///   external drops call `DropImportCoordinator`, synchronously adding items
///   and finishing asynchronous materializations through callbacks.

@MainActor
final class DragContainerView: NSView {
    private static let reorderActivationRatio: CGFloat = 0.10
    private let store: ShelfStore
    private let dropHandler: ShelfDropHandler
    private let dropTargetState: DropTargetState
    private let gridGeometry: ShelfGridGeometry
    private let dropOverride: DragContainerDropOverride?
    private let onDestinationEntered: (Int) -> Void
    private let onDestinationEnded: (Int, Bool) -> Void
    private var currentDestinationSequenceNumber: Int?
    /// Smoothed travel of the dragged card center, used to tell a horizontal
    /// find-the-slot move from a vertical row change.
    private var reorderTravel = CGVector.zero
    private var lastReorderCenter: CGPoint?
    /// `addSubview` retains only the view, so the controller is held here.
    private let contentViewController: NSViewController

    init(store: ShelfStore,
         dropHandler: ShelfDropHandler,
         dropTargetState: DropTargetState,
         gridGeometry: ShelfGridGeometry,
         dropOverride: DragContainerDropOverride? = nil,
         onDestinationEntered: @escaping (Int) -> Void = { _ in },
         onDestinationEnded: @escaping (Int, Bool) -> Void = { _, _ in },
         contentViewController: NSViewController) {
        self.store = store
        self.dropHandler = dropHandler
        self.dropTargetState = dropTargetState
        self.gridGeometry = gridGeometry
        self.dropOverride = dropOverride
        self.onDestinationEntered = onDestinationEntered
        self.onDestinationEnded = onDestinationEnded
        self.contentViewController = contentViewController
        super.init(frame: .zero)

        // The Island paints only its custom silhouette. Keep both AppKit host
        // layers genuinely transparent so the rectangular NSView bounds never
        // become a gray plate behind the screen-attached surface.
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let contentView = contentViewController.view
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        registerForDraggedTypes(PasteboardTypes.dragInTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragContainerView is created programmatically")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        currentDestinationSequenceNumber = sender.draggingSequenceNumber
        onDestinationEntered(sender.draggingSequenceNumber)
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else {
                dropTargetState.reset()
                return []
            }
            dropTargetState.isTargeted = true
            dropTargetState.insertionIndex = nil
            dropTargetState.mode = .copy
            dropTargetState.isReordering = false
            return .copy
        }
        if let source = shelfReorderSource(from: sender) {
            resetReorderTravel()
            dropTargetState.isTargeted = true
            dropTargetState.mode = .copy
            dropTargetState.isReordering = true
            updateReorderInsertionIndex(sender, source: source)
            return .copy
        }
        // Ordinary internal drags are not imported back into the shelf. A
        // Shelf reorder is handled above; tutorial drags retain their import
        // path so onboarding can finish normally.
        guard dropHandler.accepts(sender) else { return [] }
        dropTargetState.isTargeted = true
        dropTargetState.isReordering = false
        updateDropMode(sender)
        updateExternalInsertionIndex(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // The global monitor delivers drag-start on the main actor. Repeating
        // this idempotent registration also covers entering before that delivery.
        onDestinationEntered(sender.draggingSequenceNumber)
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else {
                dropTargetState.reset()
                return []
            }
            dropTargetState.isTargeted = true
            dropTargetState.isReordering = false
            return .copy
        }
        if let source = shelfReorderSource(from: sender) {
            dropTargetState.isTargeted = true
            dropTargetState.isReordering = true
            updateReorderInsertionIndex(sender, source: source)
            return .copy
        }
        guard dropHandler.accepts(sender) else { return [] }
        dropTargetState.isReordering = false
        updateDropMode(sender)
        updateExternalInsertionIndex(sender)

        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetReorderTravel()
        dropTargetState.reset()
        dropOverride?.reset()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        var accepted = false
        defer { onDestinationEnded(sender.draggingSequenceNumber, accepted) }
        if let dropOverride, dropOverride.isActive() {
            guard dropOverride.canHandle(dropContext(sender)) else { return false }
            accepted = dropOverride.perform(dropContext(sender))
            if accepted { (sender.draggingSource as? DragSessionController)?.acceptedByFolderCopy = true }
            return accepted
        }
        if let source = shelfReorderSource(from: sender) {
            updateReorderInsertionIndex(sender, source: source)
            let destination = dropTargetState.insertionIndex ?? store.items.count
            accepted = store.move(ids: source.topLevelItemIDs, toOffset: destination)
            if accepted { source.acceptShelfReorder() }
            return accepted
        }
        accepted = dropHandler.performDrop(sender, at: dropTargetState.insertionIndex)
        return accepted
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Cancellation, rejection, or a drop elsewhere has no perform callback.
        // After perform this is an idempotent no-op in the session state machine.
        onDestinationEnded(sender.draggingSequenceNumber, false)
        guard currentDestinationSequenceNumber == sender.draggingSequenceNumber else { return }
        currentDestinationSequenceNumber = nil
        resetReorderTravel()
        dropTargetState.reset()
        dropOverride?.reset()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resetReorderTravel()
        dropTargetState.reset()
        dropOverride?.reset()
    }

    // MARK: - Helpers

    private func dropContext(_ sender: NSDraggingInfo) -> DragContainerDropContext {
        .init(pasteboard: sender.draggingPasteboard,
              location: CGPoint(x: sender.draggingLocation.x, y: bounds.height - sender.draggingLocation.y),
              isInternal: sender.draggingSource != nil,
              internalItems: (sender.draggingSource as? DragSessionController)?.itemsForFolderCopy)
    }

    private func updateDropMode(_ sender: NSDraggingInfo) {
        dropTargetState.mode = dropHandler.mode(for: sender.draggingPasteboard)
    }

    @discardableResult
    private func updateExternalInsertionIndex(_ sender: NSDraggingInfo) -> Int {
        let location = sender.draggingLocation
        let point = CGPoint(x: location.x, y: bounds.height - location.y)
        let insertionIndex = insertionIndex(for: point)
        dropTargetState.insertionIndex = insertionIndex
        return insertionIndex
    }

    /// Internal reorder follows the dragged card center rather than the mouse
    /// pointer, so grabbing any edge of a wide card behaves symmetrically.
    private func updateReorderInsertionIndex(_ sender: NSDraggingInfo,
                                             source: DragSessionController) {
        let rawLocation = sender.draggingLocation
        let offset = source.dragAnchorOffset
        let centerLocation = CGPoint(x: rawLocation.x + offset.width,
                                     y: rawLocation.y + offset.height)
        let point = CGPoint(x: centerLocation.x,
                            y: bounds.height - centerLocation.y)
        let activation = reorderActivation(following: point)
        let insertionIndex = insertionIndex(
            for: point,
            activation: activation,
            activationRatio: Self.reorderActivationRatio
        )
        dropTargetState.insertionIndex = insertionIndex
    }

    /// Horizontal drags keep the entry-edge thresholds so both directions feel
    /// equally eager. Rows entered from above or below have no horizontal entry
    /// edge: using one leaves the slot about one card off in the travel
    /// direction and forces an extra sideways push, so vertical-dominant drags
    /// fall back to the card's horizontal center.
    private func reorderActivation(following point: CGPoint)
        -> DropInsertionLocator.Activation {
        if let last = lastReorderCenter {
            let dx = point.x - last.x
            let dy = point.y - last.y
            reorderTravel = CGVector(dx: reorderTravel.dx * 0.65 + dx * 0.35,
                                     dy: reorderTravel.dy * 0.65 + dy * 0.35)
        }
        lastReorderCenter = point
        guard abs(reorderTravel.dx) >= abs(reorderTravel.dy),
              reorderTravel.dx != 0 else {
            return .center
        }
        return reorderTravel.dx > 0 ? .leading : .trailing
    }

    private func insertionIndex(for point: CGPoint,
                                activation: DropInsertionLocator.Activation = .center,
                                activationRatio: CGFloat = 0.10) -> Int {
        let frames: [(index: Int, frame: CGRect)] = store.items.enumerated().compactMap { index, item in
            gridGeometry.cardFrames[item.id].map { (index, $0) }
        }
        return DropInsertionLocator.insertionIndex(
            for: point,
            frames: frames,
            itemCount: store.items.count,
            activation: activation,
            activationRatio: activationRatio
        )
    }

    private func shelfReorderSource(from sender: NSDraggingInfo) -> DragSessionController? {
        guard let source = sender.draggingSource as? DragSessionController,
              source.canReorderOnShelf,
              store.visibleItems.count == store.items.count,
              source.topLevelItemIDs.isSubset(of: Set(store.items.map(\.id))),
              !dropHandler.isTutorialDrag(sender.draggingPasteboard) else {
            return nil
        }
        return source
    }

    /// A new drag must not inherit the direction of the previous one.
    private func resetReorderTravel() {
        reorderTravel = .zero
        lastReorderCenter = nil
    }
}
