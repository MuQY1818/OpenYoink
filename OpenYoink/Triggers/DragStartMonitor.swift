import AppKit

/// UX1 拖拽开始识别（纯逻辑状态机，与 AppKit 解耦供单测）：
/// 左键按下记录起点 → 按住移动、与起点的直线位移达到阈值判定「拖拽开始」
/// （恰好回调一次）→ 左键抬起结束。
///
/// 阈值采用「与按下点的位移」而非「路径累计长度」：点击按住不放时手的微颤
/// 会累计路径长度但几乎不产生位移，位移判据不会把「按住不放」误判为拖拽。
struct DragGestureTracker: Sendable, Equatable {
    /// 状态机相位。
    enum Phase: String, Sendable, Equatable {
        /// 左键未按下。
        case idle
        /// 已按下、尚未确认拖拽（位移未达阈值）。
        case pressing
        /// 已确认拖拽（阈值已跨越、已回调）。
        case dragging
    }

    /// 拖拽判定位移阈值（点）。~8pt 与系统拖拽启动阈值同量级。
    static let defaultThreshold: CGFloat = 8

    private(set) var phase: Phase = .idle
    private var origin: CGPoint = .zero
    let threshold: CGFloat

    init(threshold: CGFloat = Self.defaultThreshold) {
        self.threshold = threshold
    }

    /// 左键按下：记录起点，进入 pressing。（漏抬起的防护：按下总是重置会话。）
    mutating func mouseDown(at point: CGPoint) {
        phase = .pressing
        origin = point
    }

    /// 按住移动采样。返回 `true` 恰好一次 —— 位移首次达到阈值的时刻；
    /// 此后本次拖拽的继续移动恒返回 `false`。
    mutating func mouseDragged(to point: CGPoint) -> Bool {
        guard phase == .pressing else { return false }
        guard hypot(point.x - origin.x, point.y - origin.y) >= threshold else { return false }
        phase = .dragging
        return true
    }

    /// 左键抬起。返回 `true` 表示本次抬起结束了一个已确认的拖拽；
    /// 普通点击（未达阈值）返回 `false`。
    mutating func mouseUp() -> Bool {
        defer { phase = .idle }
        return phase == .dragging
    }

    /// 复位（停止监听时调用，丢弃半会话）。
    mutating func reset() {
        phase = .idle
    }
}

/// UX1: 全局拖拽开始监听（计划外 UX 批次，对齐 Yoink「开始拖拽即出现」）。
///
/// 沙箱合规：`NSEvent.addGlobalMonitorForEvents` 监听
/// `leftMouseDown/leftMouseDragged/leftMouseUp` 无需 Accessibility 权限
/// （只读、不消费事件）。global monitor 覆盖其他应用内的拖拽，local
/// monitor 覆盖从本应用窗口（shelf 卡片拖出等）起始的拖拽。
///
/// 注册生命周期与 `MouseShakeMonitor` 一致：monitor 只存在于 `start` 与
/// `stop` 之间；`start` 幂等。识别核心 `DragGestureTracker` 为纯类型。
///
/// 回调语义：
/// - `onDragStart`：位移阈值首次跨越（忽略列表前台时经 `shouldSuppress` 抑制）；
/// - `onDragEnd`：已确认拖拽的左键抬起或拖拽源会话结束（不被抑制 ——
///   抑制即无会话，配合 `DragAutoShowSession` 空转安全）。
///
/// EdgeTab: `isDragInProgress` 是可观察的「拖拽进行中」状态（阈值确认即置位，
/// 不受 `shouldSuppress` 影响 —— 抑制只挡唤出，不改变「正在拖拽」的事实），
/// 供边缘拉环做投放暗示高亮；抬起、拖拽源结束或 `stop()` 复位。
@MainActor
@Observable
final class DragStartMonitor {
    /// Whether the event monitors are currently registered.
    private(set) var isMonitoring = false

    /// EdgeTab: 已确认的拖拽会话进行中（阈值跨越 → 抬起）。
    private(set) var isDragInProgress = false

    private var tracker: DragGestureTracker?
    private var fileDragTracker = EdgeFileDragTracker()
    private let eventSource: DragEventSource
    /// Events queued before a drag source reports completion must not re-arm
    /// the trackers when their MainActor task runs afterwards.
    private var eventCutoff: TimeInterval = 0

    /// Ignore-list gate, evaluated only at the moment a drag is confirmed.
    private let shouldSuppress: @MainActor () -> Bool
    private let onDragStart: @MainActor () -> Void
    private let onDragUpdate: @MainActor (CGPoint) -> Void
    private let onDragEnd: @MainActor () -> Void

    init(eventSource: DragEventSource = DragEventSource(),
         shouldSuppress: @escaping @MainActor () -> Bool,
         onDragStart: @escaping @MainActor () -> Void,
         onDragUpdate: @escaping @MainActor (CGPoint) -> Void = { _ in },
         onDragEnd: @escaping @MainActor () -> Void) {
        self.eventSource = eventSource
        self.shouldSuppress = shouldSuppress
        self.onDragStart = onDragStart
        self.onDragUpdate = onDragUpdate
        self.onDragEnd = onDragEnd
    }

    /// Registers the monitors. Idempotent: starting while monitoring is a no-op.
    func start() {
        guard !isMonitoring else { return }
        tracker = DragGestureTracker()

        eventSource.start(.start) { [weak self] sample in
            self?.handle(eventType: sample.mouse.type, at: sample.mouse.location,
                         timestamp: sample.mouse.timestamp, snapshot: sample.pasteboard)
        }
        isMonitoring = true
    }

    /// Removes all event registrations.
    func stop() {
        eventSource.stop(.start)
        tracker = nil
        fileDragTracker.reset()
        isMonitoring = false
        isDragInProgress = false
    }

    /// Closes the current monitor session regardless of tracker phase. Source
    /// callbacks and mouse-up can both report the same end; only the first one
    /// while active publishes `onDragEnd`.
    func finishDrag(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        eventCutoff = max(eventCutoff, timestamp)
        let wasDragging = isDragInProgress
        tracker?.reset()
        fileDragTracker.reset()
        isDragInProgress = false
        guard wasDragging else { return }
        onDragEnd()
    }

    /// Internal so tests can drive exact event order without synthesizing
    /// system events. Production callers use the event monitors registered by
    /// `start()`.
    func handle(eventType: NSEvent.EventType,
                at point: CGPoint,
                timestamp: TimeInterval,
                snapshot: DragPasteboardSnapshot) {
        guard isMonitoring, timestamp > eventCutoff else { return }
        switch eventType {
        case .leftMouseDown:
            tracker?.mouseDown(at: point)
            fileDragTracker.mouseDown(changeCount: snapshot.changeCount)
        case .leftMouseDragged:
            guard fileDragTracker.mouseDragged(
                changeCount: snapshot.changeCount,
                hasFileContent: PasteboardTypes.hasFileDragContent(in: snapshot.types)
            ) else { return }
            let didBegin = tracker?.mouseDragged(to: point) == true
            guard tracker?.phase == .dragging else { return }
            // EdgeTab: 投放暗示状态与抑制无关 —— 被抑制（忽略列表 / 正在拖动
            // 拉环本身）的拖拽依然是「拖拽进行中」，只是不触发唤出。
            isDragInProgress = true
            // 抑制（忽略列表前台）只影响唤出，不破坏跟踪器状态：抬起时
            // onDragEnd 照常到达，会话裁决（未 dragBegan）空转。
            guard !shouldSuppress() else { return }
            if didBegin { onDragStart() }
            onDragUpdate(point)
        case .leftMouseUp:
            finishDrag(at: timestamp)
        default:
            break
        }
    }
}
