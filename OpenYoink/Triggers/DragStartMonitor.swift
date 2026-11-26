import AppKit

struct DragGestureTracker: Sendable, Equatable {
    enum Phase: String, Sendable, Equatable {
        case idle
        /// Down, below the threshold.
        case pressing
        /// The threshold was crossed.
        case dragging
    }

    /// Of the same order as the system's own drag threshold.
    static let defaultThreshold: CGFloat = 8

    private(set) var phase: Phase = .idle
    private var origin: CGPoint = .zero
    let threshold: CGFloat

    init(threshold: CGFloat = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// Always restarts, in case a mouse-up was missed.
    mutating func mouseDown(at point: CGPoint) {
        phase = .pressing
        origin = point
    }

    mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard phase == .pressing else { return false }
        guard hypot(point.x - origin.x, point.y - origin.y) >= threshold else { return false }
        phase = .dragging
        return true
    }

    mutating func mouseUp() -> Bool {
        defer { phase = .idle }
        return phase == .dragging
    }

    mutating func reset() {
        phase = .idle
    }
}

@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    private(set) var isDragInProgress = false

    private var tracker: DragGestureTracker?
    private var fileDragTracker = EdgeFileDragTracker()
    private let eventSource: DragEventSource
    /// Events queued before a drag source reports completion must not re-arm
    /// the trackers when their MainActor task runs afterwards.
    private var eventCutoff: TimeInterval = 0

    /// Ignore-list gate, evaluated only at the moment a drag is confirmed.
    private let shouldSuppress: @MainActor () -> Bool
    private let onDragStart: @MainActor () -> Void
    private let onDragUpdate: @MainActor (CGPoint) -> Void
    private let onDragEnd: @MainActor () -> Void

    init(eventSource: DragEventSource = DragEventSource(),
         shouldSuppress: @escaping @MainActor () -> Bool,
         onDragStart: @escaping @MainActor () -> Void,
         onDragUpdate: @escaping @MainActor (CGPoint) -> Void = { _ in },
         onDragEnd: @escaping @MainActor () -> Void) {
        self.eventSource = eventSource
        self.shouldSuppress = shouldSuppress
        self.onDragStart = onDragStart
        self.onDragUpdate = onDragUpdate
        self.onDragEnd = onDragEnd
    }

    /// Registers the monitors. Idempotent: starting while monitoring is a no-op.
    func start() {
        guard !isMonitoring else { return }
        tracker = DragGestureTracker()

        eventSource.start(.start) { [weak self] sample in
            self?.handle(eventType: sample.mouse.type, at: sample.mouse.location,
                         timestamp: sample.mouse.timestamp, snapshot: sample.pasteboard)
        }
        isMonitoring = true
    }

    /// Removes all event registrations.
    func stop() {
        eventSource.stop(.start)
        tracker = nil
        fileDragTracker.reset()
        isMonitoring = false
        isDragInProgress = false
    }

    /// Closes the current monitor session regardless of tracker phase. Source
    /// callbacks and mouse-up can both report the same end; only the first one
    /// while active publishes `onDragEnd`.
    func finishDrag(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        eventCutoff = max(eventCutoff, timestamp)
        let wasDragging = isDragInProgress
        tracker?.reset()
        fileDragTracker.reset()
        isDragInProgress = false
        guard wasDragging else { return }
        onDragEnd()
    }

    /// Internal so tests can drive exact event order without synthesizing
    /// system events. Production callers use the event monitors registered by
    /// `start()`.
    func handle(eventType: NSEvent.EventType,
                at point: CGPoint,
                timestamp: TimeInterval,
                snapshot: DragPasteboardSnapshot) {
        guard isMonitoring, timestamp > eventCutoff else { return }
        switch eventType {
        case .leftMouseDown:
            tracker?.mouseDown(at: point)
            fileDragTracker.mouseDown(changeCount: snapshot.changeCount)
        case .leftMouseDragged:
            guard fileDragTracker.mouseDragged(
                changeCount: snapshot.changeCount,
                hasFileContent: PasteboardTypes.hasFileDragContent(in: snapshot.types)
            ) else { return }
            let didBegin = tracker?.mouseDragged(to: point) == true
            guard tracker?.phase == .dragging else { return }

            isDragInProgress = true
            // Suppression only blocks summoning; the tracker keeps going so
            // mouse-up still arrives.
            guard !shouldSuppress() else { return }
            if didBegin { onDragStart() }
            onDragUpdate(point)
        case .leftMouseUp:
            finishDrag(at: timestamp)
        default:
            break
        }
    }
}
