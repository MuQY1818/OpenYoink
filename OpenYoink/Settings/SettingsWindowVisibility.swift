import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SettingsWindowVisibility {
    var displaysContent = false
}

/// Both settings entry points cache their root. Keep this observer mounted
/// while removing hidden windows' Form/List content and live preview.
struct SettingsWindowVisibilityReader: NSViewRepresentable {
    let visibility: SettingsWindowVisibility

    func makeNSView(context: Context) -> SettingsWindowVisibilityView {
        SettingsWindowVisibilityView(visibility: visibility)
    }

    func updateNSView(_ view: SettingsWindowVisibilityView, context: Context) {
        view.visibility = visibility
    }

    static func dismantleNSView(_ view: SettingsWindowVisibilityView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class SettingsWindowVisibilityView: NSView {
    var visibility: SettingsWindowVisibility {
        didSet { if oldValue !== visibility { scheduleRefresh() } }
    }
    private var visibleObservation: NSKeyValueObservation?
    private var miniaturizedObservation: NSKeyValueObservation?
    private var generation: UInt = 0

    init(visibility: SettingsWindowVisibility) {
        self.visibility = visibility
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("Created programmatically") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            // Observe visibility itself: ordering out/in need not generate key
            // or expose notifications. NSWindow mutations occur on MainActor.
            visibleObservation = window.observe(\.isVisible, options: [.new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === observed else { return }
                    self.scheduleRefresh()
                }
            }
            miniaturizedObservation = window.observe(\.isMiniaturized, options: [.new]) { [weak self] observed, _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === observed else { return }
                    self.scheduleRefresh()
                }
            }
        }
        scheduleRefresh()
    }

    func stopObserving() {
        generation &+= 1
        visibleObservation?.invalidate()
        miniaturizedObservation?.invalidate()
        visibleObservation = nil
        miniaturizedObservation = nil
    }

    private func scheduleRefresh() {
        generation &+= 1
        let request = generation
        // Defer SwiftUI state writes until after AppKit attachment/layout.
        // Coalesce changes and invalidate callbacks from a previous window.
        Task { @MainActor [weak self] in
            guard let self, self.generation == request else { return }
            self.visibility.displaysContent = self.window?.isVisible == true
                && self.window?.isMiniaturized == false
        }
    }
}
