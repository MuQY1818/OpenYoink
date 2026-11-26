/// UX1/2: 一次拖拽会话中 shelf 自动显隐的裁决（纯逻辑，与 AppKit 解耦）。
///
/// 语义（用户确认）：
/// - 拖拽驱动唤出 shelf 时打 `shownAutomatically` 标记（仅当唤出前 shelf
///   不可见 —— 拖拽前已可见说明是用户手动唤出的，本轮不动它）；
/// - 本轮拖拽中有内容成功落入 shelf（`DropImportCoordinator.onImportHandled`）
///   → `noteImport()` 复位「无落入」假设；
/// - 拖拽结束：未投放则收回；成功投放默认保持展开，可由用户关闭。
/// - 已进入本地接收区时等待 AppKit 的投放结果，而不是猜测回调延迟。
struct DragAutoShowSession: Sendable, Equatable {
    /// 本轮是否处于已确认的拖拽会话中（mouseDown 阈值跨越 → mouseUp）。
    private(set) var isDragging = false
    /// 本轮拖拽是否触发了自动唤出（唤出时 shelf 原本不可见）。
    private(set) var shownAutomatically = false
    /// 本轮拖拽中是否已有内容成功入架。
    private(set) var receivedImport = false
    private var destinationSequenceNumber: Int?
    private var destinationDidEnd = false
    private var destinationAccepted = false
    private var keepAfterDrop = true

    /// 拖拽开始（阈值跨越）：开启新会话，清空上一轮的全部标记。
    mutating func dragBegan() {
        self = Self()
        isDragging = true
    }

    /// 标记「本次显示为拖拽驱动的自动唤出」。不在拖拽会话中（如快捷键
    /// 唤出、剪贴板保存唤出）时忽略 —— 那些是显式意图，不参与自动收回。
    mutating func markShownAutomatically() {
        guard isDragging else { return }
        shownAutomatically = true
    }

    /// 本轮有内容成功入架（同步导入或已派发异步物化）。
    mutating func noteImport() {
        receivedImport = true
    }

    /// A real AppKit destination owns completion once it has seen this drag.
    /// Keep the identity after exit: draggingEnded also covers cancellation or
    /// a drop elsewhere. A late callback from an older drag cannot close a new one.
    mutating func destinationEntered(sequenceNumber: Int) {
        guard isDragging,
              destinationSequenceNumber == nil || destinationSequenceNumber == sequenceNumber else { return }
        destinationSequenceNumber = sequenceNumber
    }

    /// Returns a hide decision only after BOTH mouse-up and destination completion.
    mutating func destinationEnded(sequenceNumber: Int, accepted: Bool) -> Bool {
        guard destinationSequenceNumber == sequenceNumber, !destinationDidEnd else { return false }
        destinationDidEnd = true
        destinationAccepted = accepted
        return isDragging ? false : finish()
    }

    /// Explicit show/hide takes ownership away from automatic presentation.
    mutating func cancelAutomaticHide() {
        shownAutomatically = false
    }

    mutating func dragEnded(keepShelfOpenAfterDrop: Bool = true) -> Bool {
        guard isDragging else { return false }
        isDragging = false
        keepAfterDrop = keepShelfOpenAfterDrop
        if destinationSequenceNumber != nil && !destinationDidEnd { return false }
        return finish()
    }

    private mutating func finish() -> Bool {
        defer { self = Self() }
        let accepted = destinationSequenceNumber == nil ? receivedImport : destinationAccepted
        return shownAutomatically && !(accepted && keepAfterDrop)
    }
}
