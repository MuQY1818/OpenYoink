import AppKit
import QuartzCore

@MainActor
enum PanelFrameAnimation {
    static func animate(_ panel: NSPanel, to frame: NSRect, duration: TimeInterval,
                        timing: CAMediaTimingFunction, alpha: CGFloat? = nil,
                        completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            if let alpha { panel.animator().alphaValue = alpha }
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}
