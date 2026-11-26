import AppKit
import SwiftUI

struct IslandSurfaceRevealModifier: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var opacity: Double
    let collapsedWidth: CGFloat
    let collapsedHeight: CGFloat
    let attachedToScreenTop: Bool

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, opacity) }
        set {
            progress = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let clampedProgress = min(max(progress, 0), 1)
                    let minimumWidth = min(collapsedWidth, proxy.size.width)
                    let minimumHeight = min(collapsedHeight, proxy.size.height)
                    let revealedWidth = minimumWidth
                        + (proxy.size.width - minimumWidth) * clampedProgress
                    let revealedHeight = minimumHeight
                        + (proxy.size.height - minimumHeight) * clampedProgress
                    IslandSurfaceShape(
                        attachedToScreenTop: attachedToScreenTop,
                        cornerRadius: 26
                    )
                    .fill(Color.white)
                    .frame(width: revealedWidth, height: revealedHeight,
                           alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                }
            }
            .opacity(opacity)
    }
}
