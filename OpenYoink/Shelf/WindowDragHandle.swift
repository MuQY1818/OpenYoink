import AppKit
import SwiftUI

/// The window drag handle for custom placement.
///
/// A transparent NSView over ShelfView's title bar: mouse-down enters
/// AppKit's standard window drag loop (`performDrag(with:)`, which follows
/// across screens and respects their bounds), and `onDragEnded` hands the
/// final frame (screen coordinates) up for persisting.
///
/// Not `isMovableByWindowBackground`: a draggable background would fight
/// card drags and ScrollView scrolling; limiting it to the title bar avoids
/// that.
@MainActor
final class WindowDragHandleView: NSView {
    /// The window's final frame, in global screen coordinates.
    var onDragEnded: ((NSRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WindowDragHandleView is created programmatically")
    }

    /// A click enters the drag loop; with a non-activating panel,
    /// `acceptsFirstMouse` makes the first click drag even while the app is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        window.performDrag(with: event)
        onDragEnded?(window.frame)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// The SwiftUI bridge (see ShelfView.header; custom placement only).
struct WindowDragHandle: NSViewRepresentable {
    var onDragEnded: @MainActor (NSRect) -> Void

    func makeNSView(context: Context) -> WindowDragHandleView {
        let view = WindowDragHandleView()
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }
}
