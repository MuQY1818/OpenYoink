import AppKit
import OSLog
import SwiftUI

/// 一次拖出的内容集合，由卡片事件层（ShelfView / Stack 浮层）计算。
struct DragOutContents: Equatable, Sendable {
    /// 实际拖出的项目（顶层选择集合或浮层子项集合；stack 由
    /// `DragPayloadBuilder.flattenedItems` 展开为子项）。
    var items: [ShelfItem]
    /// 涉及的顶层项目 id：drop 成功且策略为移除时从 store 删除。
    /// Stack 浮层子项拖出传空集 —— 子项的移除语义（unstack 局部移除）
    /// 随 S6 的 stack 批量操作一起设计，本步不移除子项。
    var topLevelIDs: Set<UUID>
}

/// Tutorial 卡与普通多选拖拽之间的隔离规则（纯函数，避免练习 token 搭便车）。
enum TutorialDragScope {
    static func effectiveContents(_ contents: DragOutContents,
                                  originatingItemID: UUID,
                                  tutorialItemIDs: Set<UUID>) -> DragOutContents {
        let tutorialOrigin = tutorialItemIDs.contains(originatingItemID)
        return DragOutContents(
            items: contents.items.filter { item in
                tutorialOrigin
                    ? item.id == originatingItemID
                    : !tutorialItemIDs.contains(item.id)
            },
            topLevelIDs: tutorialOrigin
                ? contents.topLevelIDs.intersection([originatingItemID])
                : contents.topLevelIDs.subtracting(tutorialItemIDs)
        )
    }
}

/// 拖出总控（MainActor）：把卡片 mouseDragged 转成 AppKit 拖拽会话。
///
/// 经 SwiftUI 环境（`\.dragOutController`）注入卡片；Preview/测试中环境缺省
/// 为 nil，卡片拖拽静默关闭、点击不受影响。
@MainActor
final class DragOutController {
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let bookmarkService: BookmarkService
    /// Long-lived delivery state survives the AppKit drag session because file
    /// promise callbacks may arrive before or after `endedAt`.
    private let deliveryCoordinator: DeliveryCoordinator
    /// 活动练习卡的运行时令牌。令牌只随该卡本次拖出写入 pasteboard；普通
    /// 项目返回 nil。闭包避免把 tutorial 状态写进 ShelfItem schema。
    private let tutorialTokenForItem: @MainActor (UUID) -> String?
    /// Balances the shared drag-start monitor when AppKit ends this dragging
    /// session. The closure is optional for previews and isolated tests.
    private let onSourceDragEnded: (@MainActor () -> Void)?

    /// S8: 拖出成功（`operation` 非空）后的回调，由 ShelfWindowController
    /// 在 init 完成后接线以实现 autoHide（init 期无法捕获未完成的 self）。
    /// 为 nil 时不做任何事（Preview/测试）。
    var onSuccessfulDrop: (@MainActor () -> Void)?

    init(store: ShelfStore,
         settings: SettingsStore,
         recents: RecentItemsService,
         bookmarkService: BookmarkService,
         deliveryCoordinator: DeliveryCoordinator,
         onSourceDragEnded: (@MainActor () -> Void)? = nil,
         tutorialTokenForItem: @escaping @MainActor (UUID) -> String? = { _ in nil }) {
        self.store = store
        self.settings = settings
        self.recents = recents
        self.bookmarkService = bookmarkService
        self.deliveryCoordinator = deliveryCoordinator
        self.onSourceDragEnded = onSourceDragEnded
        self.tutorialTokenForItem = tutorialTokenForItem
    }

    /// 拖拽启动入口：`CardDragSourceAnchorView` 在 mouseDragged 超阈值时经卡片
    /// 回调调用。必须在主线程、且 `event` 为当前手势的 mouseDown/mouseDragged
    /// 事件（`beginDraggingSession` 的硬性要求）。
    func beginDrag(contents: DragOutContents,
                   originatingItemID: UUID,
                   from sourceView: NSView,
                   event: NSEvent) {
        // 练习 token 绝不能搭便车混进普通多选拖拽：从练习卡起拖时只拖
        // 练习卡；从普通卡起拖时剔除可能被选中的练习卡。这样教程目标接受
        // token 时不会连带触发其他用户卡片的移除/最近项目策略。
        let tutorialIDs = Set(contents.items.compactMap { item in
            tutorialTokenForItem(item.id) == nil ? nil : item.id
        })
        let effectiveContents = TutorialDragScope.effectiveContents(
            contents,
            originatingItemID: originatingItemID,
            tutorialItemIDs: tutorialIDs
        )
        let sessionID = UUID()
        let dragAnchorOffset = Self.dragAnchorOffset(from: sourceView, event: event)
        let deliveryCoordinator = deliveryCoordinator
        deliveryCoordinator.noteSessionBegan(id: sessionID, contents: effectiveContents)
        let sink = DeliverySink(
            promiseRequested: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.notePromiseRequested(sessionID: sessionID,
                                                             itemID: itemID)
                }
            },
            delivered: { itemID, url in
                Task { @MainActor in
                    deliveryCoordinator.noteDelivered(sessionID: sessionID,
                                                      itemID: itemID,
                                                      destination: url)
                }
            },
            failed: { itemID in
                Task { @MainActor in
                    deliveryCoordinator.noteFailed(sessionID: sessionID, itemID: itemID)
                }
            }
        )
        let fileAccess = DragPayloadBuilder.makeFileAccessLease(
            for: effectiveContents.items,
            bookmarkService: bookmarkService
        )
        let flattenedPreviewItems = effectiveContents.items.flattened
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: effectiveContents.items,
            frame: sourceView.bounds,
            bookmarkService: bookmarkService,
            delivery: sink,
            tutorialTokensByItemID: Dictionary(
                uniqueKeysWithValues: effectiveContents.items.flattened.compactMap { item in
                    tutorialTokenForItem(item.id).map { (item.id, $0) }
                }
            ),
            cardPreviewImage: flattenedPreviewItems.count == 1
                ? Self.makeCardPreview(for: flattenedPreviewItems[0],
                                       appearance: settings.appearance)
                : nil
        )
        guard !draggingItems.isEmpty else {
            deliveryCoordinator.noteSessionEnded(id: sessionID, accepted: false)
            return
        }
        // 每次会话独立的 NSDraggingSource：无复用状态，结果处理只依赖本次 contents。
        let source = DragSessionController(contents: effectiveContents,
                                           sessionID: sessionID,
                                           store: store,
                                           settings: settings,
                                           recents: recents,
                                           delivery: deliveryCoordinator,
                                           policyExcludedItemIDs: Set(
                                               effectiveContents.items.flattened.compactMap { item in
                                                   tutorialTokenForItem(item.id) == nil ? nil : item.id
                                               }
                                           ),
                                           onSuccessfulDrop: onSuccessfulDrop,
                                           dragAnchorOffset: dragAnchorOffset,
                                           fileAccess: fileAccess,
                                           onSourceDragEnded: onSourceDragEnded)
        // Counted only once a session really starts: the source's
        // `draggingSession(_:endedAt:)` is the matching decrement, and the early
        // return above has no session to end.
        deliveryCoordinator.noteDragSessionStarted()
        sourceView.beginDraggingSession(with: draggingItems, event: event, source: source)
    }

    /// Draws the drag preview at the same size the item occupies in the shelf:
    /// the card's thumbnail area is a fixed 52pt-high box with aspect-fit, so a
    /// portrait image stays narrow and a document keeps its square icon.
    private static func makeCardPreview(for item: ShelfItem,
                                        appearance: ShelfAppearance) -> NSImage? {
        let thumbnail = thumbnailImage(for: item)
        let aspect = thumbnail.flatMap { image -> CGFloat? in
            guard image.size.width > 0, image.size.height > 0 else { return nil }
            return image.size.height / image.size.width
        } ?? 1
        let thumbnailHeight: CGFloat = 52
        let thumbnailWidth = min(max(thumbnailHeight / max(aspect, 0.1), 20), 88)
        let labelHeight: CGFloat = 18
        let width = max(thumbnailWidth, 64)
        let size = NSSize(width: width,
                          height: (thumbnailHeight + labelHeight + 4).rounded())

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = size

        let isDark = appearance.theme.colorScheme.map { $0 == .dark }
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let thumbnailRect = NSRect(x: (width - thumbnailWidth) / 2,
                                   y: labelHeight + 4,
                                   width: thumbnailWidth,
                                   height: thumbnailHeight)
        if let thumbnail {
            drawAspectFit(thumbnail, in: thumbnailRect, cornerRadius: 6)
        }

        let labelRect = NSRect(x: 0, y: 0, width: width, height: labelHeight)
        (isDark ? NSColor(calibratedWhite: 0.24, alpha: 0.94)
                : NSColor(calibratedWhite: 0.97, alpha: 0.96)).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (item.displayName as NSString).draw(
            with: labelRect.insetBy(dx: 5, dy: 3),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .regular),
                .foregroundColor: isDark
                    ? NSColor.white.withAlphaComponent(0.92)
                    : NSColor.black.withAlphaComponent(0.75),
                .paragraphStyle: paragraph
            ]
        )

        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static func thumbnailImage(for item: ShelfItem) -> NSImage? {
        if let cached = DragImageCache.image(for: item.id) {
            return NSImage(cgImage: cached,
                           size: NSSize(width: cached.width, height: cached.height))
        }
        if let path = item.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let symbolName = switch item.kind {
        case .text: "doc.text"
        case .url: "link"
        default: "doc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private static func drawAspectFit(_ image: NSImage, in rect: NSRect, cornerRadius: CGFloat) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - drawSize.width / 2,
                              y: rect.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Offset from the current pointer to the source card center, in window
    /// coordinates. Adding it to a dragging location yields the card center.
    private static func dragAnchorOffset(from sourceView: NSView,
                                         event: NSEvent) -> CGSize {
        guard sourceView.window != nil else { return .zero }
        let center = sourceView.convert(
            NSPoint(x: sourceView.bounds.midX, y: sourceView.bounds.midY),
            to: nil
        )
        let pointer = event.locationInWindow
        return CGSize(width: center.x - pointer.x,
                      height: center.y - pointer.y)
    }
}


private struct DragOutControllerEnvironmentKey: EnvironmentKey {
    // nil 缺省：Preview 与单测中拖拽关闭（点击仍工作）。
    static var defaultValue: DragOutController? { nil }
}

extension EnvironmentValues {
    /// 拖出总控；由 ShelfWindowController 在面板内容根上注入。
    var dragOutController: DragOutController? {
        get { self[DragOutControllerEnvironmentKey.self] }
        set { self[DragOutControllerEnvironmentKey.self] = newValue }
    }
}
