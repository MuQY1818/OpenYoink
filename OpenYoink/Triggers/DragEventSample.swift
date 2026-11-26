import AppKit

struct DragPasteboardSnapshot: Sendable {
    let changeCount: Int
    let typeIdentifiers: [String]

    var types: [NSPasteboard.PasteboardType] {
        typeIdentifiers.map { NSPasteboard.PasteboardType($0) }
    }

    nonisolated static func current() -> DragPasteboardSnapshot {
        let pasteboard = NSPasteboard(name: .drag)
        return DragPasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            typeIdentifiers: pasteboard.types?.map(\.rawValue) ?? []
        )
    }
}

struct DragEventSample: Sendable {
    let mouse: MouseEventSample
    let pasteboard: DragPasteboardSnapshot

    nonisolated init(_ event: NSEvent) {
        mouse = MouseEventSample(event)
        pasteboard = .current()
    }
}

@MainActor
final class DragEventSource {
    enum Listener: CaseIterable {
        case edge, start
    }

    private var handlers: [Listener: (DragEventSample) -> Void] = [:]
    private lazy var monitor = EventMonitor(
        matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
        capture: { DragEventSample($0) },
        handler: { [weak self] sample in
            guard let self else { return }
            for listener in Listener.allCases { handlers[listener]?(sample) }
        }
    )

    func start(_ listener: Listener, handler: @escaping (DragEventSample) -> Void) {
        handlers[listener] = handler
        monitor.start()
    }

    func stop(_ listener: Listener) {
        handlers.removeValue(forKey: listener)
        if handlers.isEmpty { monitor.stop() }
    }
}
