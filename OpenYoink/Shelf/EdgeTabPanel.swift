import AppKit

/// The edge tab's window: a small resident strip on the screen edge.
///
/// Same baseline as `ShelfPanel`: non-activating, borderless, floating, on
/// every Space and beside full-screen apps; transparent, with vibrancy,
/// corners and stroke drawn by `EdgeTabView`. `EdgeTabController` drives the
/// show/hide and emphasis animations.
@MainActor
final class EdgeTabPanel: NSPanel {
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

        // Transparent: EdgeTabView draws the inward corners, vibrancy and stroke.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Fades and emphasis frame animations are driven by EdgeTabController.
        animationBehavior = .none
    }
}
