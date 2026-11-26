import AppKit
import SwiftUI

extension ShelfWindowController {
    func makePanel(
        presentationStyle: ShelfPresentationStyle,
        dropTargetState: DropTargetState,
        gridGeometry: ShelfGridGeometry,
        dragOutController: DragOutController
    ) -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero,
                                size: NSSize(width: settings.shelfWidth, height: 600)),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // SwiftUI presentation preferences alone don't set AppKit controls'
        // appearance inside this custom, non-activating Island panel.
        if presentationStyle == .island {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        // S4: DragContainerView（NSDraggingDestination）包裹 hosting 视图。
        let hostingController = NSHostingController(
            rootView: ShelfPresentationRootView(
                presentationStyle: presentationStyle,
                onPerformRecovery: { [weak self] action in
                    self?.itemRecoveryController.perform(action)
                },
                onOpenSettings: { [weak self] in
                    self?.onOpenSettings()
                }
            )
                .environment(store)
                .environment(dropTargetState)
                .environment(settings)
                .environment(gridGeometry)
                .environment(interaction)
                .environment(notices)
                .environment(transferStore)
                .environment(islandActivityCoordinator)
                .environment(islandModules.islandModuleRegistry)
                .environment(islandModules.islandModuleContainer)
                .environment(islandModules.islandTimerStore)
                .environment(islandModules.powerSourceMonitor)
                .environment(islandModules.nowPlayingModuleStore)
                .environment(islandModules.systemStatusModuleStore)
                .environment(islandModules.aiUsageModuleStore)
                .environment(islandModules.favoriteFoldersStore)
                .environment(favoriteFolderDropCoordinator)
                .environment(clipboardHistoryStore)
                .environment(islandModules.recentDownloadsStore)
                .environment(\.bookmarkService, bookmarkService)
                .environment(\.dragOutController, dragOutController)
                .environment(\.quickLookCoordinator, quickLookCoordinator)
                .environment(\.tempFileService, tempFileService)
                .environment(\.itemRecoveryController, itemRecoveryController)
                .environment(\.shelfActionRunner, shelfActionRunner)
                .environment(\.accessibilityAnnouncementCenter,
                              accessibilityAnnouncementCenter)
                // 任务三：内缘收起把手点击 → 走标准 hideShelf 滑出动画。
                .environment(\.shelfRevealState,
                             presentationStyle == .classic ? classicReveal : nil)
                .environment(\.shelfHideAction, { [weak self] in
                    if presentationStyle == .island {
                        self?.collapseIsland(animated: true)
                    } else {
                        self?.hideShelf(animated: true)
                    }
                })
                .environment(\.shelfFocusAction, { [weak panel] in
                    guard let panel else { return }
                    panel.makeKey()
                    if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor {
                        panel.makeFirstResponder(nil)
                    }
                })
                .environment(\.shelfUserRemovalAction, { [weak self] action in
                    guard let self else { action(); return }
                    self.withUserRemoval(action)
                })
        )
        let dropOverride: DragContainerDropOverride? = presentationStyle == .island
            ? DragContainerDropOverride(
                isActive: { [weak self] in
                    guard let self else { return false }
                    return self.islandActivityCoordinator.surfaceState.isExpanded
                        && [.folders, .clipboard].contains(self.islandActivityCoordinator.selectedModule)
                },
                canHandle: { [weak self] context in
                    guard let self, self.islandActivityCoordinator.selectedModule == .folders else { return false }
                    return self.favoriteFolderDropCoordinator.update(context)
                },
                perform: { [weak self] context in
                    guard let self, self.islandActivityCoordinator.selectedModule == .folders else { return false }
                    return self.favoriteFolderDropCoordinator.perform(context)
                },
                reset: { [weak self] in self?.favoriteFolderDropCoordinator.resetTarget() }
            )
            : nil
        panel.contentView = DragContainerView(
            store: store,
            dropHandler: dropHandler,
            dropTargetState: dropTargetState,
            gridGeometry: gridGeometry,
            dropOverride: dropOverride,
            onDestinationEntered: { [weak self] sequenceNumber in
                guard presentationStyle == .classic else { return }
                self?.onClassicDestinationEntered?(sequenceNumber)
            },
            onDestinationEnded: { [weak self] sequenceNumber, accepted in
                guard presentationStyle == .classic else { return }
                self?.onClassicDestinationEnded?(sequenceNumber, accepted)
            },
            contentViewController: hostingController
        )
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        // S6: 键盘链路入口 —— 卡片单击已让面板成为 key，未被内容消费的
        // keyDown 到达这里（空格/Delete/Esc，见 handleItemKeyDown）。
        panel.onKeyDown = { [weak self] event in
            guard let self else { return false }
            return keyboardRouter.handle(event, in: panel, isIsland: presentationStyle == .island,
                                         module: islandActivityCoordinator.selectedModule)
        }
        return panel
    }
}
