import Observation
import SwiftUI

/// 侧边 shelf「从拉环长出 / 收回拉环」的形变状态（issue #10）。
///
/// 拉环与 shelf 是同一元素的两种形态：展开时面板窗口直接就位到目标 frame，
/// 只有 SwiftUI 内的玻璃面从拉环矩形弹性生长到整面板，内容随后淡入；收起
/// 反向。窗口 frame 全程不动，因此网格不会在动画中重排，拖入/框选几何也
/// 不受影响（与 Island「固定画布 + 形变」同一思路）。
///
/// 内容保持最终布局，只在生长中的玻璃形状内被「揭开」（mask），不缩放、
/// 不会漂在玻璃外；弹簧不回弹，避免玻璃越界被窗口裁出硬边。
///
/// 由 `ShelfWindowController` 驱动；`ShelfInteractiveGlassSurface` 读取。
/// 所有状态变更都在显式 `withAnimation` 中完成，视图层不挂隐式动画，
/// 因此「无动画就位」只需直接赋值。
@Observable
@MainActor
final class ShelfRevealState {
    /// 玻璃面处于展开形态（false = 收拢在拉环处）。
    private(set) var isGlassExpanded = true
    /// 面板内容可见（与玻璃错拍：展开时稍后淡入，收起时先淡出）。
    private(set) var isContentVisible = true
    /// 收拢形态的玻璃矩形（玻璃面局部坐标，左上原点）；nil = 只淡入淡出。
    private(set) var collapsedRect: CGRect?
    /// 拖文件唤出时，形变期间整块玻璃面都接收拖放（否则只有拉环那一小块
    /// 不透明，前几百毫秒松手会落空）。
    var capturesWholeSurface = false

    static let expandGlassAnimation = Animation.spring(response: 0.40, dampingFraction: 0.9)
    static let expandContentAnimation = Animation.easeOut(duration: 0.24).delay(0.06)
    static let collapseGlassAnimation = Animation.spring(response: 0.30, dampingFraction: 1)
    static let collapseContentAnimation = Animation.easeIn(duration: 0.12)
    /// 悬停预览：更快、几乎不回弹，指针掠过时不显拖沓。
    static let quickExpandGlassAnimation = Animation.spring(response: 0.30, dampingFraction: 0.95)
    static let quickExpandContentAnimation = Animation.easeOut(duration: 0.16).delay(0.05)
    /// 展开在视觉上稳定所需时长（之后恢复窗口阴影）。
    static let expandSettleDuration: TimeInterval = 0.45
    static let quickExpandSettleDuration: TimeInterval = 0.34
    /// 收起完成时长（之后 orderOut、拉环淡入）。
    static let collapseDuration: TimeInterval = 0.3

    /// 当前玻璃矩形：展开为整个玻璃面，收拢为拉环矩形。
    func glassRect(in bounds: CGRect) -> CGRect {
        guard !isGlassExpanded, let collapsedRect else { return bounds }
        return collapsedRect
    }

    /// 无动画收拢到拉环处（面板 orderFront 之前调用）。
    func prepareCollapsed(at rect: CGRect?) {
        collapsedRect = rect
        isGlassExpanded = false
        isContentVisible = false
    }

    /// 无动画直接处于展开态（减弱动态效果、custom 位置或非动画显示）。
    func showImmediately() {
        isGlassExpanded = true
        isContentVisible = true
        capturesWholeSurface = false
    }

    func expand(quick: Bool = false) {
        withAnimation(quick ? Self.quickExpandGlassAnimation : Self.expandGlassAnimation) {
            isGlassExpanded = true
        }
        withAnimation(quick ? Self.quickExpandContentAnimation : Self.expandContentAnimation) {
            isContentVisible = true
        }
    }

    func collapse(to rect: CGRect?) {
        withAnimation(Self.collapseContentAnimation) { isContentVisible = false }
        // 收拢目标在内容淡出时同步更新（拉环可能已因设置变化移动）。
        collapsedRect = rect
        withAnimation(Self.collapseGlassAnimation) { isGlassExpanded = false }
    }
}

private struct ShelfRevealStateEnvironmentKey: EnvironmentKey {
    static var defaultValue: ShelfRevealState? { nil }
}

extension EnvironmentValues {
    /// 侧边 shelf 的拉环形变状态；Island / Preview 为 nil（始终展开）。
    var shelfRevealState: ShelfRevealState? {
        get { self[ShelfRevealStateEnvironmentKey.self] }
        set { self[ShelfRevealStateEnvironmentKey.self] = newValue }
    }
}
