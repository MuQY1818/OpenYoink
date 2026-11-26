import Foundation
import Observation

@MainActor
@Observable
final class ShelfNoticeModel {
    /// nil when nothing is shown.
    private(set) var message: String?

    /// Seconds before it fades.
    static let displayDuration: TimeInterval = 4

    private var dismissalTask: Task<Void, Never>?

    /// A new notice replaces the old one and restarts the timer.
    func show(_ message: String) {
        dismissalTask?.cancel()
        self.message = message
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
