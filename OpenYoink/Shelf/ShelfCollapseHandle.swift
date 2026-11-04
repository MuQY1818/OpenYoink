import SwiftUI

/// 收起动作的环境注入：标题栏收起按钮与贴缘隐形热区共用（沿用本项目自定义
/// EnvironmentKey 模式；nil 缺省：Preview/单测中按钮渲染但点击为空操作）。
private struct ShelfHideActionEnvironmentKey: EnvironmentKey {
    static var defaultValue: (@MainActor () -> Void)? { nil }
}

extension EnvironmentValues {
    /// 收起动作；由 ShelfWindowController 在面板内容根上注入。
    var shelfHideAction: (@MainActor () -> Void)? {
        get { self[ShelfHideActionEnvironmentKey.self] }
        set { self[ShelfHideActionEnvironmentKey.self] = newValue }
    }
}
