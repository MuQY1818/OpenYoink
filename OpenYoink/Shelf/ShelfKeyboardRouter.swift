import AppKit
import OpenYoinkModuleCore

@MainActor
final class ShelfKeyboardRouter {
    private let settings: SettingsStore
    private let store: ShelfStore
    private let interaction: ShelfInteractionState
    private let favoriteFoldersStore: FavoriteFoldersStore
    private let bookmarkService: BookmarkService
    private let notices: ShelfNoticeModel
    private let shelfActionRunner: ShelfActionRunner
    private let itemRecoveryController: ItemRecoveryController
    private let quickLookCoordinator: QuickLookCoordinator
    private let tempFileService: TempFileService
    private let hideShelf: (Bool) -> Void
    private let collapseIsland: (Bool) -> Void
    private let withUserRemoval: (() -> Bool) -> Bool

    init(settings: SettingsStore,
         store: ShelfStore,
         interaction: ShelfInteractionState,
         favoriteFoldersStore: FavoriteFoldersStore,
         bookmarkService: BookmarkService,
         notices: ShelfNoticeModel,
         shelfActionRunner: ShelfActionRunner,
         itemRecoveryController: ItemRecoveryController,
         quickLookCoordinator: QuickLookCoordinator,
         tempFileService: TempFileService,
         hideShelf: @escaping (Bool) -> Void,
         collapseIsland: @escaping (Bool) -> Void,
         withUserRemoval: @escaping (() -> Bool) -> Bool) {
        self.settings = settings
        self.store = store
        self.interaction = interaction
        self.favoriteFoldersStore = favoriteFoldersStore
        self.bookmarkService = bookmarkService
        self.notices = notices
        self.shelfActionRunner = shelfActionRunner
        self.itemRecoveryController = itemRecoveryController
        self.quickLookCoordinator = quickLookCoordinator
        self.tempFileService = tempFileService
        self.hideShelf = hideShelf
        self.collapseIsland = collapseIsland
        self.withUserRemoval = withUserRemoval
    }

    // MARK: - Item keyboard handling

    /// Complete keyboard path for the visible shelf. Focus remains independent
    /// from multi-selection; only Shift+Arrow extends selection.

    func handle(_ event: NSEvent, in sourcePanel: ShelfPanel, isIsland: Bool, module: IslandModuleID) -> Bool {
        if let editor = sourcePanel.firstResponder as? NSTextView, editor.isFieldEditor { return false }
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifiers.subtract([.capsLock, .function, .numericPad])

        // The global summon shortcut is user-configurable and may equal one
        // of the fixed quick-action combinations below. In that case it keeps
        // priority; never execute a shelf action from the same key press.
        if settings.hotKeyEnabled,
           let globalShortcut = settings.hotKeyShortcut,
           HotKeyMonitor.matches(event, shortcut: globalShortcut) {
            return false
        }

        if event.keyCode == 53, modifiers.isEmpty {
            handleEscape(isIsland: isIsland, module: module)
            return true
        }

        if isIsland, module == .clipboard { return false }
        if isIsland, module == .folders {
            return handleFavoriteFoldersKeyDown(event, modifiers: modifiers)
        }

        if modifiers == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            return performKeyboardAction(.copyPath)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "j" {
            return performKeyboardAction(.revealInFinder)
        }
        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            return performKeyboardAction(.share, relativeTo: sourcePanel.contentView)
        }

        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                return store.undoLastRemoval()
            case "a":
                selectAllVisibleItems()
                return true
            case "c":
                return copyKeyboardItems()
            default:
                return false
            }
        }

        if modifiers.isEmpty || modifiers == .shift {
            let extending = modifiers == .shift
            let direction: ShelfArrowDirection?
            switch event.keyCode {
            case 123: direction = .left
            case 124: direction = .right
            case 125: direction = .down
            case 126: direction = .up
            default: direction = nil
            }
            if let direction {
                return moveKeyboardFocus(
                    direction,
                    extendingSelection: extending,
                    panelWidth: sourcePanel.frame.width
                )
            }
        }

        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 49: // Space
            return quickLookCoordinator.toggle(contextItem: focusedItem())
        case 36, 76: // Return / keypad Enter
            return openFocusedItem()
        case 51, 117: // Delete / Forward Delete
            return withUserRemoval { removeKeyboardItems() }
        default:
            return false
        }
    }

    private func handleEscape(isIsland: Bool, module: IslandModuleID) {
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isIsland, module == .clipboard {
            collapseIsland(true)
        } else if isIsland, module == .folders {
            collapseIsland(animated)
        } else if quickLookCoordinator.isPreviewing {
            quickLookCoordinator.dismiss()
        } else if interaction.isSelecting {
            interaction.isSelecting = false
            store.clearSelection()
        } else if isIsland {
            collapseIsland(animated)
        } else if interaction.expandedStackID != nil {
            interaction.exitStack()
        } else if !store.selection.isEmpty {
            store.clearSelection()
        } else {
            hideShelf(animated)
        }
    }

    private func handleFavoriteFoldersKeyDown(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 123: return favoriteFoldersStore.selectRelative(delta: -1)
        case 124: return favoriteFoldersStore.selectRelative(delta: 1)
        case 125: return favoriteFoldersStore.selectRelative(delta: 2)
        case 126: return favoriteFoldersStore.selectRelative(delta: -2)
        case 36, 76: return favoriteFoldersStore.openSelected()
        case 51, 117: return favoriteFoldersStore.removeSelected()
        default:
            return false
        }
    }

    private func visibleKeyboardItems() -> [ShelfItem] {
        interaction.visibleItems(in: store.visibleItems)
    }

    private func focusedItem() -> ShelfItem? {
        let visible = visibleKeyboardItems()
        if let focusedItemID = interaction.focusedItemID,
           let item = visible.first(where: { $0.id == focusedItemID }) {
            return item
        }
        return nil
    }

    private func moveKeyboardFocus(_ direction: ShelfArrowDirection,
                                   extendingSelection: Bool,
                                   panelWidth: CGFloat) -> Bool {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return false }
        let currentIndex: Int
        if let focusedItemID = interaction.focusedItemID,
           let index = visible.firstIndex(where: { $0.id == focusedItemID }) {
            currentIndex = index
        } else if interaction.expandedStackID == nil,
                  let selected = visible.firstIndex(where: { store.selection.contains($0.id) }) {
            currentIndex = selected
        } else {
            currentIndex = 0
        }
        let destination = ShelfKeyboardNavigator.destinationIndex(
            currentIndex: currentIndex,
            itemCount: visible.count,
            columnCount: ShelfLayoutEngine.columnCount(forPanelWidth: panelWidth),
            direction: direction
        )
        interaction.focusedItemID = visible[destination].id
        if extendingSelection {
            let extendingIDs: Set<UUID> = [visible[currentIndex].id, visible[destination].id]
            if interaction.expandedStackID != nil {
                interaction.childSelection.formUnion(extendingIDs)
            } else {
                store.setSelection(store.selection.union(extendingIDs))
            }
        }
        return true
    }

    private func selectAllVisibleItems() {
        let visible = visibleKeyboardItems()
        guard !visible.isEmpty else { return }
        if interaction.expandedStackID != nil {
            interaction.childSelection = Set(visible.map(\.id))
        } else {
            store.selectAllVisible()
        }
        if interaction.focusedItemID == nil {
            interaction.focusedItemID = visible[0].id
        }
    }

    private func keyboardActionItems() -> [ShelfItem] {
        let visible = visibleKeyboardItems()
        if interaction.expandedStackID != nil {
            let selected = visible.filter { interaction.childSelection.contains($0.id) }
            if !selected.isEmpty { return selected }
        } else {
            let selected = visible.filter { store.selection.contains($0.id) }
            if !selected.isEmpty { return selected }
        }
        if interaction.isSelecting { return [] }
        guard let focusedItemID = interaction.focusedItemID,
              let focused = visible.first(where: { $0.id == focusedItemID }) else { return [] }
        return [focused]
    }

    private func copyKeyboardItems() -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let result = ClipboardController.copy(
            items,
            bookmarkService: bookmarkService
        )
        notices.show(ClipboardController.statusMessage(for: result))
        return true
    }

    private func performKeyboardAction(_ action: ShelfAction,
                                       relativeTo anchorView: NSView? = nil) -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty, ShelfActionCatalog.canPerform(action, on: items) else {
            return false
        }
        shelfActionRunner.perform(action, on: items, relativeTo: anchorView)
        return true
    }

    private func openFocusedItem() -> Bool {
        guard let item = focusedItem() else { return false }
        if interaction.isSelecting, interaction.expandedStackID == nil {
            store.toggleSelection(item.id)
            return true
        }
        if item.availability != .available {
            itemRecoveryController.recover(item)
            return true
        }
        if item.kind == .stack {
            if interaction.expandedStackID == item.id {
                interaction.exitStack()
            } else {
                interaction.enterStack(item)
            }
            return true
        }
        guard ItemActions.canOpen(item) else { return false }
        ItemActions.open(item,
                         bookmarkService: bookmarkService,
                         tempFileService: tempFileService)
        return true
    }

    private func removeKeyboardItems() -> Bool {
        let items = keyboardActionItems()
        guard !items.isEmpty else { return false }
        let ids = Set(items.map(\.id))
        if let stackID = interaction.expandedStackID {
            guard store.removeChildrenForUser(ids: ids, fromStack: stackID) else { return false }
            interaction.childSelection.subtract(ids)
        } else {
            do {
                try store.removeBatchForUser(ids: ids)
            } catch {
                notices.show(String(localized: "Could not save a recovery copy. Nothing was removed."))
                return true
            }
        }
        interaction.normalize(for: store.items)
        quickLookCoordinator.refreshPreview(contextItem: focusedItem())
        return true
    }
}
