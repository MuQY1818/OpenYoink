import AppKit

@MainActor
final class AppServices {
    private static let uiTestingDefaultsSuite = "com.weijue.OpenYoink.UITests"

    private static func makeSettingsDefaults() -> UserDefaults {
        guard AppPaths.isUITesting else { return .standard }
        guard let defaults = UserDefaults(suiteName: uiTestingDefaultsSuite) else {
            fatalError("Unable to create the isolated UI-testing defaults suite")
        }
        defaults.removePersistentDomain(forName: uiTestingDefaultsSuite)
        return defaults
    }

    let appState = AppState()
    private let persistence = PersistenceController()
    private let bookmarkService = BookmarkService()
    private let tempFileService = TempFileService()

    private let managedMoveJournal = ManagedMoveJournal()
    /// file-promise staging/finalization recovery. Lazy construction
    /// keeps its managed root identical to TempFileService in every build.
    private lazy var pendingImportJournal = PendingImportJournal(
        managedDirectoryURL: tempFileService.directoryURL
    )
    private let shelfNotice = ShelfNoticeModel()
    private let transferStore = TransferStore()
    private let onboardingDragContext = OnboardingDragContext()

    private lazy var initialShelfLoadResult = persistence.loadResult()
    private lazy var shelfStore = ShelfStore(items: initialShelfLoadResult.contents,
                                             persistence: persistence)
    private lazy var cutMoveService = CutMoveService(
        tempFileService: tempFileService, bookmarkService: bookmarkService, managedMoveJournal: managedMoveJournal
    )
    private lazy var promiseReceiver = FilePromiseReceiver(
        tempFileService: tempFileService, bookmarkService: bookmarkService,
        pendingImportJournal: pendingImportJournal, transferStore: transferStore
    )
    lazy var dropImportCoordinator = DropImportCoordinator(
        bookmarkService: bookmarkService, tempFileService: tempFileService,
        noticeCenter: shelfNotice, managedMoveJournal: managedMoveJournal,
        pendingImportJournal: pendingImportJournal, transferStore: transferStore,
        cutMoveService: cutMoveService, promiseReceiver: promiseReceiver
    )
    let settingsStore = SettingsStore(defaults: AppServices.makeSettingsDefaults())
    lazy var clipboardHistoryStore: ClipboardHistoryStore = {
        let history = ClipboardHistoryStore(settings: settingsStore)
        history.onAddToShelf = { [weak self] content in self?.shelfImporter.addHistoryToShelf(content) }
        history.onShowWindow = { [weak self] in self?.clipboardHistoryWindowController.show() }
        return history
    }()
    private lazy var clipboardHistoryWindowController = ClipboardHistoryWindowController(
        history: clipboardHistoryStore, settings: settingsStore
    )
    let settingsNavigation = SettingsNavigationModel()
    let launchAtLoginController = LaunchAtLoginController()
    lazy var storageManagementController = StorageManagementController(
        persistence: persistence,
        tempFileService: tempFileService,
        shelfStore: shelfStore,
        managedMoveJournal: managedMoveJournal,
        pendingImportJournal: pendingImportJournal,
        bookmarkService: bookmarkService,
        additionalProtectedPaths: { [weak self] in
            (self?.deliveryCoordinator.protectedMaterializedPaths ?? [])
                .union(self?.islandModules.favoriteFolderDropCoordinator.protectedPaths ?? [])
        },
        prepareRestoredItems: { [weak self] items in
            guard let self else { return items }
            return items.map { self.maintenance.refreshedByResolvingBookmark($0) ?? $0 }
        }
    )
    private let recentItemsService = RecentItemsService()
    /// shared drag-out acceptance/promise-delivery coordinator. Storage
    /// cleanup consults its runtime file leases.
    private lazy var deliveryCoordinator = DeliveryCoordinator(
        store: shelfStore,
        recents: recentItemsService,
        tempFileService: tempFileService,
        transferStore: transferStore
    )

    lazy var updateController = UpdateController(settings: settingsStore)
    /// Help, voluntary issue reporting and privacy-safe local diagnostics.
    lazy var supportController = SupportController(settings: settingsStore)

    private lazy var dropHandler = ShelfDropHandler(
        store: shelfStore, coordinator: dropImportCoordinator, notices: shelfNotice
    )
    private lazy var islandModules = IslandModules(
        settings: settingsStore, bookmarkService: bookmarkService, transferStore: transferStore
    )
    private lazy var quickLookCoordinator = QuickLookCoordinator(
        store: shelfStore, bookmarkService: bookmarkService, tempFileService: tempFileService
    )
    private lazy var itemRecoveryController: ItemRecoveryController = ItemRecoveryController(
        store: shelfStore, bookmarkService: bookmarkService, notices: shelfNotice,
        openStorageRecovery: { [weak self] in self?.settingsWindowController.show(pane: .storage) }
    )
    private lazy var shelfActionRunner = ShelfActionRunner(bookmarkService: bookmarkService, notices: shelfNotice)
    private let accessibilityAnnouncementCenter = AccessibilityAnnouncementCenter()

    private func makeDragOutController() -> DragOutController {
        DragOutController(
            store: shelfStore, settings: settingsStore, recents: recentItemsService,
            bookmarkService: bookmarkService, deliveryCoordinator: deliveryCoordinator,
            onSourceDragEnded: { [weak self] in self?.dragStartMonitor.finishDrag() },
            tutorialTokenForItem: { [weak self] in self?.onboardingDragContext.token(for: $0) }
        )
    }

    lazy var shelfWindowController: ShelfWindowController = ShelfWindowController(
        appState: appState, store: shelfStore, dropHandler: dropHandler,
        bookmarkService: bookmarkService, notices: shelfNotice, transferStore: transferStore,
        islandModules: islandModules, tempFileService: tempFileService, settings: settingsStore,
        classicDragOutController: makeDragOutController(), islandDragOutController: makeDragOutController(),
        quickLookCoordinator: quickLookCoordinator, itemRecoveryController: itemRecoveryController,
        shelfActionRunner: shelfActionRunner, accessibilityAnnouncementCenter: accessibilityAnnouncementCenter,
        dragStartMonitor: dragStartMonitor, clipboardHistoryStore: clipboardHistoryStore,
        onOpenSettings: { [weak self] in self?.settingsWindowController.show(pane: .general) }
    )
    lazy var onboardingController = OnboardingController(
        settings: settingsStore,
        shelfStore: shelfStore,
        shelfWindowController: shelfWindowController,
        importCoordinator: dropImportCoordinator,
        dragContext: onboardingDragContext
    )
    lazy var settingsWindowController: SettingsWindowController = SettingsWindowController(settings: settingsStore,
                                                                         hotKeyMonitor: hotKeyMonitor,
                                                                         launchAtLoginController: launchAtLoginController,
                                                                         updateController: updateController,
                                                                         storageManagementController: storageManagementController,
                                                                         navigation: settingsNavigation,
                                                                         supportController: supportController,
                                                                         clipboardHistoryStore: clipboardHistoryStore)
    lazy var menuBarController = MenuBarController(
        isShelfExpanded: { [weak self] in
            self?.shelfWindowController.isPreferredShelfExpanded ?? false
        },
        recents: recentItemsService,
        onToggleShelf: { [weak self] in
            self?.toggleShelf()
        },
        onReaddRecent: { [weak self] entry in
            self?.shelfImporter.readdRecent(entry)
        },
        onShowSettings: { [weak self] in
            self?.settingsWindowController.show()
        },
        onShowQuickStart: { [weak self] in
            self?.onboardingController.replay()
        },
        onOpenHelp: { [weak self] in
            self?.supportController.openHelp()
        },
        onReportIssue: { [weak self] in
            self?.supportController.reportIssue()
        },
        onCheckForUpdates: { [weak self] in
            self?.updateController.checkForUpdates()
        },
        onOpenManualUpdate: { [weak self] in
            self?.updateController.openManualDownloadPage()
        },
        onShowClipboardHistory: { [weak self] in
            self?.clipboardHistoryWindowController.show()
        },
        onSaveClipboardImage: { [weak self] in
            self?.shelfImporter.saveClipboardImageToShelf()
        }
    )

    lazy var hotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.hotKeyShortcut,
        onPress: { [weak self] in
            self?.toggleShelfForKeyboard()
        },
        onDoublePress: { [weak self] in
            self?.shelfImporter.saveClipboardToShelf()
        }
    )
    lazy var clipboardHotKeyMonitor = HotKeyMonitor(
        shortcut: settingsStore.clipboardHistoryShortcut, hotKeyIdentifier: 2,
        onPress: { [weak self] in self?.clipboardHistoryWindowController.show() },
        onDoublePress: {}
    )
    lazy var mouseShakeMonitor = MouseShakeMonitor(shouldSuppress: { [weak self] in
        guard let self else { return false }
        return IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        self?.toggleShelf()
    })

    private let dragEventSource = DragEventSource()
    lazy var edgeTriggerMonitor = EdgeTriggerMonitor(eventSource: dragEventSource, shouldSuppress: { [weak self] in
        guard let self else { return true }
        return self.appState.isShelfVisible
            || self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onTrigger: { [weak self] in
        guard let self, !self.appState.isShelfVisible else { return }
        self.shelfWindowController.showShelf(animated: true)
        self.dragAutoShowSession.markShownAutomatically()
    })

    lazy var dragStartMonitor = DragStartMonitor(eventSource: dragEventSource, shouldSuppress: { [weak self] in
        guard let self else { return false }
        return self.appState.isEdgeTabBeingDragged
            || IgnoreListService.frontmostAppIsIgnored(in: self.settingsStore.ignoredAppBundleIDs)
    }, onDragStart: { [weak self] in
        self?.handleDragStart()
    }, onDragUpdate: { [weak self] point in
        self?.handleDragUpdate(at: point)
    }, onDragEnd: { [weak self] in
        self?.handleDragEnd()
    })
    private var dragAutoShowSession = DragAutoShowSession()
    private var islandDragWasActivated = false

    lazy var edgeTabController: EdgeTabController = EdgeTabController(
        appState: appState,
        settings: settingsStore,
        dropHandler: dropHandler,
        onDestinationEntered: { [weak self] in
            self?.dragAutoShowSession.destinationEntered(sequenceNumber: $0)
        },
        onDestinationEnded: { [weak self] in
            self?.finishDestination(sequenceNumber: $0, accepted: $1)
        },
        dragStartMonitor: dragStartMonitor,
        onToggleShelf: { [weak self] in
            guard let self else { return }
            if appState.isShelfVisible {
                shelfWindowController.hideShelf(animated: true)
            } else {
                shelfWindowController.showShelf(animated: true)
            }
        },
        onShowShelf: { [weak self] in
            self?.shelfWindowController.showShelf(animated: true)
        }
    )

    lazy var maintenance = LaunchMaintenance(
        shelfStore: shelfStore, persistence: persistence, initialShelfLoadResult: initialShelfLoadResult,
        managedMoveJournal: managedMoveJournal, pendingImportJournal: pendingImportJournal,
        tempFileService: tempFileService, bookmarkService: bookmarkService, shelfNotice: shelfNotice
    )
    private lazy var shelfImporter = ShelfImporter(
        shelfStore: shelfStore, dropImportCoordinator: dropImportCoordinator,
        appState: appState, shelfNotice: shelfNotice, bookmarkService: bookmarkService,
        shelfWindowController: shelfWindowController
    )

    func toggleShelf() {
        shelfWindowController.toggleShelf(animated: true)
    }

    private func toggleShelfForKeyboard() {
        shelfWindowController.toggleShelfForKeyboard(animated: true)
    }

    // MARK: - Drag-triggered appearance

    func connectShelfPresentation() {
        let edgeTab = edgeTabController
        shelfWindowController.onClassicShelfHandoffChanged = { [weak edgeTab] in
            edgeTab?.synchronizeShelfHandoff()
        }
        dropImportCoordinator.onImportHandled = { [weak self] in
            self?.dragAutoShowSession.noteImport()
        }
        shelfWindowController.onClassicDestinationEntered = { [weak self] in
            self?.dragAutoShowSession.destinationEntered(sequenceNumber: $0)
        }
        shelfWindowController.onClassicDestinationEnded = { [weak self] in
            self?.finishDestination(sequenceNumber: $0, accepted: $1)
        }
        shelfWindowController.onClassicPresentationRequested = { [weak self] in
            self?.dragAutoShowSession.cancelAutomaticHide()
        }
    }

    private func finishDestination(sequenceNumber: Int, accepted: Bool) {
        if dragAutoShowSession.destinationEnded(sequenceNumber: sequenceNumber, accepted: accepted),
           appState.isShelfVisible {
            shelfWindowController.hideShelf(animated: true)
        }
    }

    private func handleDragStart() {
        dragAutoShowSession.dragBegan()
        guard settingsStore.effectivePreferredShelfSurface == .classic else { return }
        guard settingsStore.classicShelfEnabled else { return }
        guard settingsStore.dragAutoAppearMode == .immediate else { return }
        guard !appState.isShelfVisible else { return }
        shelfWindowController.showShelf(animated: true)
        dragAutoShowSession.markShownAutomatically()
    }

    private func handleDragUpdate(at point: CGPoint) {
        guard settingsStore.islandEnabled,
              settingsStore.islandShelfEnabled,
              settingsStore.islandDragApproachEnabled,
              settingsStore.dragAutoAppearMode != .off else { return }
        if shelfWindowController.islandDragApproachedTop(at: point) {
            islandDragWasActivated = true
        }
    }

    private func handleDragEnd() {
        let imported = dragAutoShowSession.receivedImport
        let shouldHideClassic = dragAutoShowSession.dragEnded(
            keepShelfOpenAfterDrop: settingsStore.keepShelfOpenAfterDrop
        )
        if islandDragWasActivated {
            shelfWindowController.islandDragEnded(imported: imported)
            islandDragWasActivated = false
        }
        guard shouldHideClassic, appState.isShelfVisible else { return }
        shelfWindowController.hideShelf(animated: true)
    }

    // MARK: - Trigger wiring

    func applyTriggerSettings() {
        hotKeyMonitor.updateShortcut(settingsStore.hotKeyShortcut)
        hotKeyMonitor.setDoublePressEnabled(settingsStore.hotKeyDoublePressSavesClipboard)
        hotKeyMonitor.setEnabled(settingsStore.hotKeyEnabled)
        clipboardHotKeyMonitor.updateShortcut(settingsStore.clipboardHistoryShortcut)
        clipboardHotKeyMonitor.setEnabled(settingsStore.clipboardHistoryShortcut != nil
            && (!settingsStore.hotKeyEnabled || settingsStore.clipboardHistoryShortcut != settingsStore.hotKeyShortcut))
        clipboardHistoryStore.shortcutRegistrationError = settingsStore.hotKeyEnabled
            && settingsStore.clipboardHistoryShortcut != nil
            && settingsStore.clipboardHistoryShortcut == settingsStore.hotKeyShortcut
            ? String(localized: "Choose a history shortcut different from the shelf shortcut.")
            : clipboardHotKeyMonitor.registrationError

        if settingsStore.shakeTriggerEnabled {
            mouseShakeMonitor.start(parameters: settingsStore.shakeSensitivity.shakeParameters)
        } else {
            mouseShakeMonitor.stop()
        }

        let classicActive = settingsStore.classicShelfEnabled
        let edgeActive = classicActive
            && settingsStore.dragAutoAppearMode == .edgeOnly
            && settingsStore.shelfPosition != .custom
        if edgeActive {
            edgeTriggerMonitor.start(
                side: settingsStore.shelfPosition,
                dwellTime: settingsStore.edgeTriggerSensitivity.edgeDwellTime,
                bandWidth: settingsStore.edgeTriggerSensitivity.edgeBandWidth
            )
        } else {
            edgeTriggerMonitor.stop()
        }

        let edgeTabActive = classicActive
            && settingsStore.edgeTabEnabled
            && settingsStore.shelfPosition != .custom
        let islandDragActive = settingsStore.islandEnabled
            && settingsStore.islandShelfEnabled
            && settingsStore.islandDragApproachEnabled
            && settingsStore.dragAutoAppearMode != .off
        let classicImmediateActive = settingsStore.effectivePreferredShelfSurface == .classic
            && settingsStore.dragAutoAppearMode == .immediate
        if classicImmediateActive
            || edgeActive || edgeTabActive || islandDragActive {
            dragStartMonitor.start()
        } else {
            dragStartMonitor.stop()
        }
    }

    func stopTriggers() {
        hotKeyMonitor.setEnabled(false)
        clipboardHotKeyMonitor.setEnabled(false)
        mouseShakeMonitor.stop()
        edgeTriggerMonitor.stop()
        dragStartMonitor.stop()
    }
}
