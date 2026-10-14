import CoreGraphics

/// Compare layout requests with the destination, not an in-flight window frame.
/// Otherwise repeated settings notifications can restart or finish a slide.
struct ShelfFrameTransitionState {
    private(set) var targetFrame: CGRect?

    mutating func request(_ frame: CGRect, currentFrame: CGRect) -> Bool {
        let previousTarget = targetFrame ?? currentFrame
        targetFrame = frame
        return previousTarget != frame
    }

    mutating func reset() {
        targetFrame = nil
    }
}
