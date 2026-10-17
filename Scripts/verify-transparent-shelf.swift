// Run from the repository root in a logged-in macOS desktop session:
// xcrun swiftc -parse-as-library OpenYoink/Appearance/ShelfAppearance.swift OpenYoink/Appearance/ShelfGlassSurface.swift Scripts/verify-transparent-shelf.swift -o /tmp/openyoink-hit-region
// /tmp/openyoink-hit-region
// This briefly displays two owned windows without moving the pointer or
// changing app preferences. A view-only hitTest cannot detect this regression:
// WindowServer may select the window underneath before AppKit sees the event.
import AppKit
import SwiftUI

@main
struct TransparentShelfVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard let screen = NSScreen.main else {
            print("FAIL: requires a logged-in macOS desktop")
            exit(1)
        }
        let frame = NSRect(x: screen.visibleFrame.midX - 180,
                           y: screen.visibleFrame.midY - 140,
                           width: 360, height: 280)
        let behind = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        behind.isReleasedWhenClosed = false
        behind.level = .floating
        behind.backgroundColor = .white
        behind.orderFront(nil)
        let shelf = NSWindow(contentRect: frame, styleMask: [.borderless],
                             backing: .buffered, defer: false)
        shelf.isReleasedWhenClosed = false
        shelf.level = .floating
        shelf.isOpaque = false
        shelf.backgroundColor = .clear
        shelf.hasShadow = false
        defer { shelf.close(); behind.close() }
        var failures = 0
        var checks = 0
        for material in ShelfAppearance.Material.allCases {
            for opacity in [0.0, 0.001, 0.01, 0.5, 1.0] {
                var appearance = ShelfAppearance()
                appearance.material = material
                appearance.backgroundOpacity = opacity
                appearance.tintStrength = 0
                let host = NSHostingView(rootView: ShelfInteractiveGlassSurface(appearance: appearance) {
                    Color.clear.overlay(alignment: .top) { Text("Shelf").padding(12) }
                }.padding(8))
                host.frame = NSRect(origin: .zero, size: frame.size)
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.clear.cgColor
                shelf.contentView = host
                shelf.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                shelf.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                // Blank center and blank side must belong to the shelf; padding
                // and the rounded-away corner must still belong to the window behind.
                for (point, expectedShelf) in [
                    (NSPoint(x: 180, y: 120), true),
                    (NSPoint(x: 12, y: 140), true),
                    (NSPoint(x: 4, y: 140), false),
                    (NSPoint(x: 9, y: 9), false),
                ] {
                    let target = NSWindow.windowNumber(at: shelf.convertPoint(toScreen: point),
                                                      belowWindowWithWindowNumber: 0)
                    checks += 1
                    if target != (expectedShelf ? shelf.windowNumber : behind.windowNumber) {
                        failures += 1
                        print("FAIL material=\(material) opacity=\(opacity) point=\(point) shelfHit=\(target == shelf.windowNumber) target=\(target) own=\(shelf.windowNumber) behind=\(behind.windowNumber) frame=\(shelf.frame)")
                    }
                }
            }
        }
        print("WindowServer hit region: \(checks - failures)/\(checks) passed")
        if failures > 0 { exit(1) }
    }
}
