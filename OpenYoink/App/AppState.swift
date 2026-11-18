import Foundation
import Observation

/// 全局应用状态（shelf 可见性等）。
///
/// SwiftUI 侧后续通过 `@Environment` 注入观察；AppKit 侧由
/// `ShelfWindowController` 在显示/隐藏面板时同步维护 `isShelfVisible`。
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

    /// EdgeTab: 拉环正被按住拖动（重定位会话进行中），由 EdgeTabController
    /// 维护。拖拽驱动的触发器（DragStartMonitor 唤出 / EdgeTriggerMonitor
    /// 贴边）据此抑制 —— 拖动拉环本身不应唤出 shelf。放在这里而非
    /// EdgeTabController：monitor 的抑制闭包若引用 controller 会造成
    /// lazy 属性循环引用（edgeTabController ⇄ dragStartMonitor）。
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

    /// EdgeTab 重定位会话开始/结束。
    func setEdgeTabBeingDragged(_ dragged: Bool) {
        isEdgeTabBeingDragged = dragged
    }
}
