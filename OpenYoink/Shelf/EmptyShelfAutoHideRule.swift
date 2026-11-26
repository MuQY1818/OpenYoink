/// Hides on a non-empty → empty transition when enabled. Explicit shelf
/// management removals and in-progress drags keep the shelf open, while still
/// advancing the baseline so a suppressed hide is never replayed later.
struct EmptyShelfAutoHideRule: Sendable, Equatable {
    private var previousCount: Int?

    /// 每次 items 变更时评估。返回 true = 应立即自动隐藏。
    /// 无论结果如何都记录本次数量作为下次基线。
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool) -> Bool {
        evaluate(itemCount: itemCount, isVisible: isVisible, isEnabled: isEnabled,
                 isDragInProgress: false)
    }

    /// Suppressed transitions still update the baseline. Future delivery-driven
    /// removals continue to follow the user's empty-shelf setting.
    mutating func evaluate(itemCount: Int, isVisible: Bool, isEnabled: Bool,
                           isDragInProgress: Bool, isUserRemoval: Bool = false) -> Bool {
        defer { previousCount = itemCount }
        guard let previousCount else { return false }
        guard !isDragInProgress, !isUserRemoval else { return false }
        return isEnabled && isVisible && previousCount > 0 && itemCount == 0
    }

    /// 清空基线（下一次评估只记录不触发）。
    mutating func reset() {
        previousCount = nil
    }
}
