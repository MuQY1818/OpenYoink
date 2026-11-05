import AppKit

/// Shelf 面板窗口。窗口行为集中于此（见实施计划 §2.3）：
/// non-activating、borderless、浮动于其他窗口之上、跨 Space、全屏辅助，
/// 透明背景 + 圆角 + vibrancy 视觉由内容层（`ShelfView`）实现。
@MainActor
final class ShelfPanel: NSPanel {
    /// Island 模式需要真正贴住屏幕物理顶边。NSWindow 默认会把很矮的窗口
    /// 约束到 `visibleFrame`（菜单栏下方），即使调用方传入的是刘海所在 frame。
    /// 经典模式继续保留 AppKit 的常规屏幕约束。
    var allowsTopEdgeOverlap = false

    /// S6: 键盘事件回调（空格 Quick Look / Delete 移除 / Esc 取消选择或关 QL）。
    /// 由 ShelfWindowController 注入；返回 true 表示事件已消费。
    /// 卡片单击会让面板成为 key（见 CardDragSourceAnchorView.mouseUp），未被
    /// SwiftUI 内容消费的 keyDown 沿 responder chain 到达这里。
    var onKeyDown: ((NSEvent) -> Bool)?

    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: backingStoreType,
                   defer: flag)

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true

        // 透明背景：圆角 / vibrancy / 描边由 ShelfView 绘制，窗口阴影跟随内容形状。
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // 显示/隐藏动画由 ShelfWindowController 用 NSAnimationContext 显式驱动。
        animationBehavior = .none
    }

    /// 修复（真机验收发现）：borderless 窗口默认 `canBecomeKeyWindow = false`，
    /// 导致 S6 的「卡片单击后 panel.makeKey()」静默失败（运行日志有
    /// `makeKeyWindow ... returned NO` 警告），空格 Quick Look / Delete / Esc
    /// 全部失效。面板需要接键盘事件但不抢 main 状态，故只放开 key。
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowsTopEdgeOverlap ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// 面板因点击空白/卡片而成为 key 时，SwiftUI 会把焦点自动交给第一个
    /// 文本框（搜索框），聚焦样式闪一下又被收走（issue：点空白处面板抖动）。
    /// 文本框只在两种情况下拿焦点：键盘操作（⌘F、Tab 等），或这次点击
    /// 确实落在该文本框上。
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let field = responder as? NSTextField, field.isEditable,
           !Self.allowsTextFocus(field, for: NSApp.currentEvent) {
            return false
        }
        return super.makeFirstResponder(responder)
    }

    private static func allowsTextFocus(_ field: NSTextField, for event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard event.window === field.window else { return false }
            // 放大镜按钮（SwiftUI 绘制，不是独立 NSView）就在文本框左侧同一行，
            // 点它同样应该进入搜索，所以按位置判断而不是按命中视图判断。
            let point = field.convert(event.locationInWindow, from: nil)
            return field.bounds.insetBy(dx: -36, dy: -8).contains(point)
        default:
            return true
        }
    }


    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}
