import AppKit
import OSLog
import SwiftUI

/// The `NSDraggingSource` of one drag-out session.
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
    /// Exercise items: onboarding cleans them up once a real target confirms;
    /// the removal policy and Recent Items never see them.
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

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

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

    /// Top-level IDs the policy may remove. Removing a cut item before its
    /// delivery is confirmed would orphan the managed copy, and the next
    /// launch's orphan cleanup would delete data that is still in transit.
    private var nonCutTopLevelIDs: Set<UUID> {
        contents.topLevelIDs.filter { id in
            !policyExcludedItemIDs.contains(id)
                && contents.items.first(where: { $0.id == id })?.isCut != true
        }
    }

    private var nonCutFlattenedItems: [ShelfItem] {
        contents.items.flattened.filter {
            !$0.isCut && !policyExcludedItemIDs.contains($0.id)
        }
    }

    /// Shared by `.remove` and a confirmed `.ask`. Children dragged out of a
    /// stack stay on the shelf but are still recorded.
    private func removeDraggedItems() {
        let ids = nonCutTopLevelIDs
        if !ids.isEmpty {
            store.remove(ids: ids)
        }
        recents.record(nonCutFlattenedItems)
    }

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

enum DragOutRemovalDecision {
    struct Verdict: Equatable, Sendable {
        var shouldRemove: Bool
        /// Set when "Don't ask again" was checked.
        var policyToPersist: SettingsStore.DragOutRemovalPolicy?
    }

    nonisolated static func verdict(removeChosen: Bool, dontAskAgain: Bool) -> Verdict {
        Verdict(shouldRemove: removeChosen,
                policyToPersist: dontAskAgain ? (removeChosen ? .remove : .keep) : nil)
    }
}

// MARK: - Delivery coordination
