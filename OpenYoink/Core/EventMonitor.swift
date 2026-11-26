import AppKit

/// What a mouse-event observer usually needs, captured on the event's own
/// turn (the pointer moves on before a main-actor hop runs).
struct MouseEventSample: Sendable {
    let type: NSEvent.EventType
    let location: CGPoint
    let timestamp: TimeInterval

    init(_ event: NSEvent) {
        type = event.type
        location = NSEvent.mouseLocation
        timestamp = event.timestamp
    }
}

/// A global + local `NSEvent` monitor pair that only observes: global
/// monitors see events sent to other apps, local ones events sent to ours.
/// `start()` and `stop()` are idempotent.
@MainActor
final class EventMonitor<Sample: Sendable> {
    private let includesLocal: Bool
    private let mask: NSEvent.EventTypeMask
    private let capture: @Sendable (NSEvent) -> Sample
    private let handler: @MainActor (Sample) -> Void
    private var globalToken: Any?
    private var localToken: Any?

    var isRunning: Bool { globalToken != nil || localToken != nil }

    init(matching mask: NSEvent.EventTypeMask,
         includesLocal: Bool = true,
         capture: @escaping @Sendable (NSEvent) -> Sample,
         handler: @escaping @MainActor (Sample) -> Void) {
        self.mask = mask
        self.includesLocal = includesLocal
        self.capture = capture
        self.handler = handler
    }

    func start() {
        guard !isRunning else { return }
        let capture = capture
        globalToken = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let sample = capture(event)
            Task { @MainActor in self?.handler(sample) }
        }
        guard includesLocal else { return }
        localToken = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let sample = capture(event)
            Task { @MainActor in self?.handler(sample) }
            return event
        }
    }

    func stop() {
        if let globalToken { NSEvent.removeMonitor(globalToken) }
        if let localToken { NSEvent.removeMonitor(localToken) }
        globalToken = nil
        localToken = nil
    }
}

extension EventMonitor where Sample == MouseEventSample {
    convenience init(matching mask: NSEvent.EventTypeMask,
                     handler: @escaping @MainActor (MouseEventSample) -> Void) {
        self.init(matching: mask, capture: { MouseEventSample($0) }, handler: handler)
    }
}
