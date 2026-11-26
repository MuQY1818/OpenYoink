import Observation
import SwiftUI

@Observable
@MainActor
final class ShelfRevealState {
    private(set) var isGlassExpanded = true
    private(set) var isContentVisible = true
    private(set) var collapsedRect: CGRect?

    var capturesWholeSurface = false

    /// `ShelfWindowController.resizeClassicSurface`）
    private(set) var surfaceHeight: CGFloat?

    private(set) var stableSurfaceHeight: CGFloat?

    static let resizeAnimation = Animation.spring(response: 0.32, dampingFraction: 1)

    static let expandGlassAnimation = Animation.spring(response: 0.40, dampingFraction: 0.9)
    static let expandContentAnimation = Animation.easeOut(duration: 0.24).delay(0.06)
    static let collapseGlassAnimation = Animation.easeOut(duration: 0.30)
    static let collapseContentAnimation = Animation.easeIn(duration: 0.12)

    static let expandSettleDuration: TimeInterval = 0.45

    func surfaceBounds(in canvas: CGRect) -> CGRect {
        guard let surfaceHeight else { return canvas }
        return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width,
                      height: max(1, min(surfaceHeight, canvas.height)))
    }

    func stableSurfaceBounds(in canvas: CGRect) -> CGRect {
        guard let stableSurfaceHeight else { return canvas }
        return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width,
                      height: max(1, min(stableSurfaceHeight, canvas.height)))
    }

    func pinSurfaceHeight(_ height: CGFloat?) {
        surfaceHeight = height
        stableSurfaceHeight = height
    }

    func animateSurfaceHeight(to height: CGFloat, completion: @escaping @MainActor () -> Void) {

        stableSurfaceHeight = height
        withAnimation(Self.resizeAnimation, completionCriteria: .logicallyComplete) {
            surfaceHeight = height
        } completion: {
            MainActor.assumeIsolated { completion() }
        }
    }

    func glassRect(in bounds: CGRect) -> CGRect {
        guard !isGlassExpanded, let collapsedRect else { return bounds }
        return collapsedRect
    }

    func prepareCollapsed(at rect: CGRect?) {
        collapsedRect = rect
        isGlassExpanded = false
        isContentVisible = false
    }

    func showImmediately() {
        isGlassExpanded = true
        isContentVisible = true
        capturesWholeSurface = false
        surfaceHeight = nil
        stableSurfaceHeight = nil
    }

    func expand() {
        withAnimation(Self.expandGlassAnimation) {
            isGlassExpanded = true
        }
        withAnimation(Self.expandContentAnimation) {
            isContentVisible = true
        }
    }

    func collapse(to rect: CGRect, completion: @escaping @MainActor () -> Void) {
        withAnimation(Self.collapseContentAnimation) { isContentVisible = false }
        collapsedRect = rect
        withAnimation(Self.collapseGlassAnimation, completionCriteria: .removed) {
            isGlassExpanded = false
        } completion: {
            MainActor.assumeIsolated { completion() }
        }
    }
}

private struct ShelfRevealStateEnvironmentKey: EnvironmentKey {
    static var defaultValue: ShelfRevealState? { nil }
}

extension EnvironmentValues {
    var shelfRevealState: ShelfRevealState? {
        get { self[ShelfRevealStateEnvironmentKey.self] }
        set { self[ShelfRevealStateEnvironmentKey.self] = newValue }
    }
}
