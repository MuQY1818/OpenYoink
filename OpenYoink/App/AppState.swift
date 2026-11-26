import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum ShelfPresentation {
        case hidden, shown, closing
    }

    private(set) var shelfPresentation: ShelfPresentation = .hidden
    /// The requested Shelf state, used by toggles and drag triggers. During
    /// closing, the window still owns the edge until the final frame is gone.
    var isShelfVisible: Bool { shelfPresentation == .shown }
    var canShowEdgeTab: Bool { shelfPresentation == .hidden }

    /// The edge tab is being dragged, maintained by EdgeTabController. The
    /// drag-driven triggers (DragStartMonitor, EdgeTriggerMonitor) stay quiet
    /// meanwhile, since dragging the tab shouldn't summon the shelf. It lives
    /// here because the monitors referencing the controller would form a lazy
    /// reference cycle (edgeTabController ⇄ dragStartMonitor).
    private(set) var isEdgeTabBeingDragged = false

    func showShelf() {
        shelfPresentation = .shown
    }

    func beginShelfClose() {
        guard shelfPresentation == .shown else { return }
        shelfPresentation = .closing
    }

    func hideShelf() {
        shelfPresentation = .hidden
    }

    func setEdgeTabBeingDragged(_ dragged: Bool) {
        isEdgeTabBeingDragged = dragged
    }
}
