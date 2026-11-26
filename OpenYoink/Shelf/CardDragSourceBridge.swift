import AppKit
import SwiftUI

struct CardDragSourceBridge: NSViewRepresentable {
    /// For debugging and logs.
    let itemID: UUID
    /// A click without a drag. Created in the view body, so it inherits main-actor
    /// isolation; spelling out `@MainActor` would trigger Sendable conversion
    /// checks.
    let onClick: (_ additive: Bool) -> Void
    /// Quick Look.
    let onDoubleClick: () -> Void
    /// Past the threshold, with the anchor view and the current event.
    let onDragBegin: (_ sourceView: NSView, _ event: NSEvent) -> Void

    func makeNSView(context: Context) -> CardDragSourceAnchorView {
        let view = CardDragSourceAnchorView()
        view.itemID = itemID
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragBegin = onDragBegin
        return view
    }

    func updateNSView(_ nsView: CardDragSourceAnchorView, context: Context) {
        nsView.itemID = itemID
        nsView.onClick = onClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragBegin = onDragBegin
    }
}

final class CardDragSourceAnchorView: NSView {
    var itemID: UUID?
    var onClick: ((_ additive: Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegin: ((_ sourceView: NSView, _ event: NSEvent) -> Void)?

    static let dragThreshold: CGFloat = 4

    private var mouseDownLocation: NSPoint?
    private var dragStarted = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return nil
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let downLocation = mouseDownLocation else { return }
        let location = event.locationInWindow
        let distance = hypot(location.x - downLocation.x, location.y - downLocation.y)
        guard distance >= Self.dragThreshold else { return }
        dragStarted = true
        onDragBegin?(self, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragStarted = false
        }
        // The dragging session owns the gesture once a drag starts, so mouse-up
        // normally doesn't arrive; never mistake a drag's end for a click.
        guard !dragStarted else { return }
        // The first click already selected; don't toggle again.
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        // Make the window key first: the entry to the panel's keyboard path
        // (`ShelfPanel.keyDown`), without activating the app.
        window?.makeKey()
        onClick?(event.modifierFlags.contains(.command))
    }
}
