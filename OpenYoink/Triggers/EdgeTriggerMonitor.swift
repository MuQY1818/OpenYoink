import AppKit

/// Pure dwell tracker for the edge trigger, decoupled from AppKit for unit
/// testing.
///
/// The cursor must stay inside the edge band continuously for `dwellTime`.
/// The tracker fires at most once per band entry: leaving the band (or
/// `reset()`) is the only way to re-arm it, so a cursor resting on the edge
/// can never retrigger in a loop.
///
/// the tracker now receives `leftMouseDragged` samples
/// (left button held) instead of `mouseMoved` — the edge trigger only fires
/// mid-drag; pure hovering no longer reveals the shelf (confirmed design
/// change). The tracker itself is input-agnostic and unchanged.
struct EdgeDwellTracker: Sendable, Equatable {
    /// Continuous dwell time (seconds) required before firing.
    let dwellTime: TimeInterval

    private var entryTime: TimeInterval?
    private var hasFired = false

    init(dwellTime: TimeInterval) {
        self.dwellTime = dwellTime
    }

    /// Feeds one sample. Returns `true` exactly once per band entry, at the
    /// moment the dwell threshold is reached.
    mutating func addSample(isInside: Bool, at time: TimeInterval) -> Bool {
        guard isInside else {
            entryTime = nil
            hasFired = false
            return false
        }
        guard !hasFired else { return false }
        guard let entry = entryTime else {
            entryTime = time
            return false
        }
        guard time - entry >= dwellTime else { return false }
        hasFired = true
        return true
    }

    /// Re-arms the tracker (same effect as the cursor leaving the band).
    mutating func reset() {
        entryTime = nil
        hasFired = false
    }
}

/// Associates drag-pasteboard content with the current mouse gesture.
///
/// `NSPasteboard.Name.drag` retains the previous drag after that gesture ends.
/// Non-file drags can therefore leave a stale `public.file-url` from an earlier
/// Finder drag visible to an out-of-session type check.
/// A file drag is eligible only after the pasteboard change count advances
/// beyond the value captured for this gesture's mouse-down event.
struct EdgeFileDragTracker: Sendable, Equatable {
    private var mouseDownChangeCount: Int?
    private var observedChangeCount: Int?
    private(set) var hasFreshFileContent = false

    mutating func mouseDown(changeCount: Int) {
        mouseDownChangeCount = changeCount
        observedChangeCount = changeCount
        hasFreshFileContent = false
    }

    mutating func mouseDragged(changeCount: Int, hasFileContent: Bool) -> Bool {
        guard let mouseDownChangeCount else { return false }
        guard observedChangeCount != changeCount else { return hasFreshFileContent }

        observedChangeCount = changeCount
        if changeCount != mouseDownChangeCount {
            hasFreshFileContent = hasFileContent
        }
        return hasFreshFileContent
    }

    mutating func mouseUp() {
        reset()
    }

    mutating func reset() {
        mouseDownChangeCount = nil
        observedChangeCount = nil
        hasFreshFileContent = false
    }
}

/// Screen-edge file-drag dwell trigger: while a real file or file promise
/// is being dragged, resting the cursor inside the band along the edge the shelf
/// attaches to for longer than the sensitivity-dependent dwell time shows the
/// shelf. Browser tabs, web URLs, text and in-memory image payloads do not arm
/// the trigger.

///
/// The screen under the cursor is resolved with
/// `ShelfWindowController.screen(containing:)` — the same rule the shelf
/// layout uses — so the trigger edge always matches the edge the panel will
/// appear on.
///
/// Registration lifecycle mirrors `MouseShakeMonitor`: monitors exist only
/// between `start` and `stop`.
@MainActor
final class EdgeTriggerMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    private var tracker: EdgeDwellTracker?
    private var fileDragTracker = EdgeFileDragTracker()
    private var side: SettingsStore.ShelfPosition = .right
    private var bandWidth: CGFloat = 4
    private let eventSource: DragEventSource

    /// Suppression gate (shelf already visible, frontmost app ignored),
    /// evaluated only when the dwell completes.
    private let shouldSuppress: @MainActor () -> Bool
    private let onTrigger: @MainActor () -> Void

    init(
        eventSource: DragEventSource = DragEventSource(),
         shouldSuppress: @escaping @MainActor () -> Bool,
        onTrigger: @escaping @MainActor () -> Void
    ) {
        self.eventSource = eventSource
        self.shouldSuppress = shouldSuppress
        self.onTrigger = onTrigger
    }

    /// (Re)starts monitoring. Idempotent for unchanged configuration.
    func start(side: SettingsStore.ShelfPosition, dwellTime: TimeInterval, bandWidth: CGFloat) {
        let unchanged = isMonitoring
            && self.side == side
            && tracker?.dwellTime == dwellTime
            && self.bandWidth == bandWidth
        guard !unchanged else { return }
        stop()

        self.side = side
        self.bandWidth = bandWidth
        tracker = EdgeDwellTracker(dwellTime: dwellTime)

        eventSource.start(.edge) { [weak self] sample in
            self?.handle(eventType: sample.mouse.type, at: sample.mouse.location,
                         timestamp: sample.mouse.timestamp, snapshot: sample.pasteboard)
        }
        isMonitoring = true
    }

    /// Removes all event registrations.
    func stop() {
        eventSource.stop(.edge)
        tracker = nil
        fileDragTracker.reset()
        isMonitoring = false
    }

    private func handle(eventType: NSEvent.EventType,
                        at point: CGPoint,
                        timestamp: TimeInterval,
                        snapshot: DragPasteboardSnapshot) {
        guard isMonitoring else { return }
        switch eventType {
        case .leftMouseDown:
            fileDragTracker.mouseDown(changeCount: snapshot.changeCount)
            tracker?.reset()
            return
        case .leftMouseUp:
            fileDragTracker.mouseUp()
            tracker?.reset()
            return
        case .leftMouseDragged:
            break
        default:
            return
        }

        let screen = ShelfWindowController.screen(containing: point)
        let isFileDrag = fileDragTracker.mouseDragged(
            changeCount: snapshot.changeCount,
            hasFileContent: PasteboardTypes.hasFileDragContent(in: snapshot.types)
        )
        let inside = isFileDrag && Self.isInsideEdgeBand(point,
                                                         screenFrame: screen.frame,
                                                         side: side,
                                                         bandWidth: bandWidth)
        guard tracker?.addSample(isInside: inside, at: timestamp) == true else { return }
        // A suppressed completion (shelf already visible, or the frontmost app
        // is on the ignore list) still counts as fired: the tracker stays
        // latched until the cursor leaves and re-enters the band, which keeps
        // a resting cursor from re-showing a shelf the user just dismissed.
        guard !shouldSuppress() else { return }
        onTrigger()
    }

    /// Pure band test: full-height strip of `bandWidth` points along the
    /// given side of `screenFrame`. Points outside the screen never count.
    /// Coordinates live in the global screen space of `NSEvent.mouseLocation`.

    nonisolated static func isInsideEdgeBand(_ point: CGPoint,
                                             screenFrame: CGRect,
                                             side: SettingsStore.ShelfPosition,
                                             bandWidth: CGFloat) -> Bool {
        guard screenFrame.contains(point) else { return false }
        switch side {
        case .right:
            return point.x >= screenFrame.maxX - bandWidth
        case .left:
            return point.x <= screenFrame.minX + bandWidth
        case .custom:
            return false
        }
    }
}
