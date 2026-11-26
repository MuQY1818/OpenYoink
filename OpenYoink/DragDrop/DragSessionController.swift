import AppKit
import OSLog
import SwiftUI


/// 单次拖出会话的 `NSDraggingSource`（每会话一个实例，无跨会话状态）。
@MainActor
final class DragSessionController: NSObject, NSDraggingSource {
    private let contents: DragOutContents
    var itemsForFolderCopy: [ShelfItem] { contents.items }
    var topLevelItemIDs: Set<UUID> { contents.topLevelIDs }
    var acceptedByFolderCopy = false
    var acceptedByShelfReorder = false
    var canReorderOnShelf: Bool {
        !topLevelItemIDs.isEmpty
            && policyExcludedItemIDs.isDisjoint(with: topLevelItemIDs)
    }
    var dragAnchorOffset: CGSize { anchorOffset }
    private let sessionID: UUID
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let delivery: DeliveryCoordinator?
    /// Tutorial 项由 OnboardingController 在真实目标确认后清理，不受用户的
    /// 常规拖出策略影响，也绝不能进入「最近项目」。
    private let policyExcludedItemIDs: Set<UUID>
    private let onSuccessfulDrop: (@MainActor () -> Void)?
    private let onSourceDragEnded: (@MainActor () -> Void)?
    private let anchorOffset: CGSize
    private var fileAccess: BookmarkAccessLease?

    init(contents: DragOutContents,
         sessionID: UUID = UUID(),
         store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         delivery: DeliveryCoordinator? = nil,
         policyExcludedItemIDs: Set<UUID> = [],
         onSuccessfulDrop: (@MainActor () -> Void)? = nil,
         dragAnchorOffset: CGSize = .zero,
         fileAccess: BookmarkAccessLease? = nil,
         onSourceDragEnded: (@MainActor () -> Void)? = nil) {
        self.contents = contents
        self.sessionID = sessionID
        self.store = store
        self.settings = settings
        self.recents = recents
        self.delivery = delivery
        self.policyExcludedItemIDs = policyExcludedItemIDs
        self.onSuccessfulDrop = onSuccessfulDrop
        self.onSourceDragEnded = onSourceDragEnded
        self.anchorOffset = dragAnchorOffset
        self.fileAccess = fileAccess
        super.init()
    }

    /// 操作掩码：只声明 `.copy`，永不声明 `.move`。
    ///
    /// 若声明 .move，Finder 目标在默认或修饰键组合下会执行「移动」—— 复制到
    /// 目标后删除原位置文件，违背「任何情况下都不删除用户原文件」（计划 §1.2；
    /// 调研报告 7.2 风险 C：最终语义由源掩码、目标返回值与修饰键共同决定，
    /// 源侧收窄是最可靠的边界）。只给 .copy 后拖到 Finder 永远是复制，
    /// ⌥/⌘ 不能把它升级为移动。
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// 会话结束处理：仅当实际 drop 发生（`operation` 非空；取消/目标拒绝为空）
    /// 才按设置策略处理 —— 移除顶层项目并记入最近历史、原样保留，或（.ask）
    /// 弹确认框。成功 drop 后先回调 onSuccessfulDrop（autoHide 接线处）。
    ///
    /// F-05: 剪切（isCut）项不参与上述策略 —— 剪切语义即移走，交付确认
    /// （promise 写入完成）后由 `DeliveryCoordinator` 移出 shelf 并删除
    /// 保管副本，不受 dragOutRemovalPolicy 影响。会话取消（operation == []）
    /// 时 cut 项与保管文件原样保留。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        completeDrag(operation: operation)
    }

    func completeDrag(operation: NSDragOperation) {
        // End the gesture before auto-hide or the removal prompt can run a nested event loop.
        onSourceDragEnded?()
        defer { fileAccess = nil }
        delivery?.noteDragSessionEnded()
        if acceptedByFolderCopy || acceptedByShelfReorder {
            delivery?.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        guard operation != [] else {
            delivery?.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        onSuccessfulDrop?()
        switch settings.dragOutRemovalPolicy {
        case .keep:
            break
        case .remove:
            removeDraggedItems()
        case .ask:
            askWhetherToRemove()
        }
        // Report acceptance after the removal policy has run. If a promise
        // failure arrived early, the coordinator can now safely reinsert the
        // failed snapshot instead of having this method remove it afterwards.
        delivery?.noteSessionEnded(id: sessionID, accepted: true)
    }

    /// Marks this session as an internal Shelf reorder. The source must not
    /// treat the destination acknowledgement as an external delivery.
    func acceptShelfReorder() {
        acceptedByShelfReorder = true
    }

    /// F-05: 剔除剪切项后的顶层 id 集合（策略移除/询问只作用于非剪切项）。
    /// 若不剔除，.remove 会在交付确认到达前就把待交付的 cut 项移架，保管
    /// 文件成孤儿（下次启动被 cleanupOrphans 删除），移动中的数据丢失。
    private var nonCutTopLevelIDs: Set<UUID> {
        contents.topLevelIDs.filter { id in
            !policyExcludedItemIDs.contains(id)
                && contents.items.first(where: { $0.id == id })?.isCut != true
        }
    }

    /// F-05: 剔除剪切项后的展开项目集合（最近历史只记非剪切项；剪切项在
    /// 交付确认时由 DeliveryCoordinator 单独记录）。
    private var nonCutFlattenedItems: [ShelfItem] {
        contents.items.flattened.filter {
            !$0.isCut && !policyExcludedItemIDs.contains($0.id)
        }
    }

    /// 移除顶层项目并记入最近历史（.remove 策略与 .ask 确认移除共用）。
    /// 浮层子项拖出 topLevelIDs 为空、不从 shelf 移除，但同样记入历史。
    private func removeDraggedItems() {
        let ids = nonCutTopLevelIDs
        if !ids.isEmpty {
            store.remove(ids: ids)
        }
        recents.record(nonCutFlattenedItems)
    }

    /// S8: .ask 策略 —— 成功拖出后询问是否从 shelf 移除；勾选
    /// 「Don't ask again」则把本次选择写回为 keep/remove 策略。
    /// F-05: 只问非剪切项（剪切项交付后自动离架，无需询问）。
    ///
    /// LSUIElement 注意点：应用无 Dock 且平时处于非活跃状态，弹 NSAlert
    /// 前必须 `NSApp.activate(ignoringOtherApps:)` 把应用提到前台，否则
    /// 对话框会落在其他应用窗口之后、看起来「什么都没发生」。
    /// runModal 是应用级模态：拖出会话此时已结束，阻塞主线程等待回答是
    /// 可接受的，也是「每次询问」语义本身所需。
    private func askWhetherToRemove() {
        let itemCount = nonCutTopLevelIDs.isEmpty
            ? nonCutFlattenedItems.count
            : nonCutTopLevelIDs.count
        guard itemCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = itemCount == 1
            ? String(localized: "Remove the dragged item from the shelf?")
            : String(localized: "Remove the \(itemCount) dragged items from the shelf?")
        alert.informativeText = String(localized: "The original files are never deleted.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let verdict = DragOutRemovalDecision.verdict(
            removeChosen: response == .alertFirstButtonReturn,
            dontAskAgain: alert.suppressionButton?.state == .on
        )
        if let policy = verdict.policyToPersist {
            settings.dragOutRemovalPolicy = policy
        }
        if verdict.shouldRemove {
            removeDraggedItems()
        }
    }
}

/// S8: .ask 策略确认框的裁决（纯逻辑，单测覆盖；NSAlert 交互本身无法
/// 无头测试）。「不再询问」勾选时把本次选择固化为后续策略。
enum DragOutRemovalDecision {
    struct Verdict: Equatable, Sendable {
        /// 本次是否从 shelf 移除。
        var shouldRemove: Bool
        /// 需要写回 SettingsStore 的固化策略；未勾选「不再询问」为 nil。
        var policyToPersist: SettingsStore.DragOutRemovalPolicy?
    }

    nonisolated static func verdict(removeChosen: Bool, dontAskAgain: Bool) -> Verdict {
        Verdict(shouldRemove: removeChosen,
                policyToPersist: dontAskAgain ? (removeChosen ? .remove : .keep) : nil)
    }
}

// MARK: - Delivery coordination
