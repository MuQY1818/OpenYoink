import AppKit

/// The shelf panel window: non-activating, borderless, floating above other
/// windows, on every Space and beside full-screen apps. The transparent
/// rounded vibrancy look comes from the content.
@MainActor
final class ShelfPanel: NSPanel {

    var allowsTopEdgeOverlap = false

    /// Key events (Space Quick Look, Delete removes, Esc clears or closes);
    /// returns true when consumed. Clicking a card makes the panel key (see
    /// `CardDragSourceAnchorView.mouseUp`), and key-downs the SwiftUI content
    /// doesn't consume travel the responder chain to here.
    var onKeyDown: ((NSEvent) -> Bool)?

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: backingStoreType,
                   defer: flag)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // Transparent: the content draws corners, vibrancy and stroke; the window
// shadow follows its shape.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Show/hide animations are driven explicitly with NSAnimationContext.
        animationBehavior = .none
    }

    /// A borderless window can't become key by default, so `makeKey()` after a
    /// card click silently failed ("makeKeyWindow ... returned NO") and Space,
    /// Delete and Esc did nothing. The panel needs key events but never main
    /// status, so only key is allowed.
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTopEdgeOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable,
           !Self.allowsTextFocus(field, for: NSApp.currentEvent) {
            return false
        }
        return super.makeFirstResponder(responder)
    }

    private static func allowsTextFocus(_ field: NSTextField, for event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard event.window === field.window else { return false }

            let point = field.convert(event.locationInWindow, from: nil)
            return field.bounds.insetBy(dx: -36, dy: -8).contains(point)
        default:
            return true
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
