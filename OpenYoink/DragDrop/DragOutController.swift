import AppKit
import OSLog
import SwiftUI

/// What one drag-out carries, computed by the card event layer.
struct DragOutContents: Equatable, Sendable {
    /// The dragged items: the top-level selection or children of the open
    /// stack. Stacks are flattened when the payload is built.
    var items: [ShelfItem]
    /// Top-level items removed from the shelf when the removal policy says
    /// so. Empty for children dragged out of an open stack: they are never
    /// removed by the policy.
    var topLevelIDs: Set<UUID>
}

/// Keeps the onboarding exercise card and ordinary cards out of each
/// other's drags, so the exercise token never rides along with user items.
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

/// Turns a card's `mouseDragged` into an AppKit dragging session.
///
/// Injected through `\.dragOutController`; without one (previews, tests)
/// cards can't be dragged but still respond to clicks.
@MainActor
final class DragOutController {
    private let store: ShelfStore
    private let settings: SettingsStore
    private let recents: RecentItemsService
    private let bookmarkService: BookmarkService
    /// Long-lived delivery state survives the AppKit drag session because file
    /// promise callbacks may arrive before or after `endedAt`.
    private let deliveryCoordinator: DeliveryCoordinator

    private let tutorialTokenForItem: @MainActor (UUID) -> String?
    /// Balances the shared drag-start monitor when AppKit ends this dragging
    /// session. The closure is optional for previews and isolated tests.
    private let onSourceDragEnded: (@MainActor () -> Void)?

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

    /// Called once a card drag passes its threshold. `event` must be the
    /// gesture's current mouse-down/dragged event, as
    /// `beginDraggingSession` requires.
    func beginDrag(contents: DragOutContents,
                   originatingItemID: UUID,
                   from sourceView: NSView,
                   event: NSEvent) {
        // Dragging the exercise card drags only it; dragging any other card
        // leaves a selected exercise card behind. A tutorial target that
        // accepts the token then never applies removal/recents to user cards.
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
        // One source per session: its result handling depends only on these contents.
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
    static var defaultValue: DragOutController? { nil }
}

extension EnvironmentValues {
    var dragOutController: DragOutController? {
        get { self[DragOutControllerEnvironmentKey.self] }
        set { self[DragOutControllerEnvironmentKey.self] = newValue }
    }
}
