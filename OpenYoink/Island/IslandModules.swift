import SwiftUI

@MainActor
final class IslandModules {
    private let settings: SettingsStore
    let recentDownloadsStore: RecentDownloadsStore
    let islandActivityCoordinator: IslandActivityCoordinator
    let islandModuleRegistry: IslandModuleRegistry
    let islandTimerStore: IslandTimerStore
    let powerSourceMonitor: PowerSourceMonitor
    let nowPlayingModuleStore: NowPlayingModuleStore
    let systemStatusModuleStore: SystemStatusModuleStore
    let aiUsageModuleStore: AIUsageModuleStore
    let favoriteFoldersStore: FavoriteFoldersStore
    let favoriteFolderDropCoordinator: FavoriteFolderDropCoordinator
    let islandModuleContainer: IslandModuleContainer
    let transfersModuleRuntime: TransfersModuleRuntime
    let timerModuleRuntime: CallbackIslandModuleRuntime
    let batteryModuleRuntime: CallbackIslandModuleRuntime
    let mediaModuleRuntime: CallbackIslandModuleRuntime
    let favoriteFoldersModuleRuntime: CallbackIslandModuleRuntime

    init(settings: SettingsStore, bookmarkService: BookmarkService, transferStore: TransferStore) {
        self.settings = settings
        self.recentDownloadsStore = RecentDownloadsStore(defaults: settings.defaultsStore,
                                                         bookmarks: bookmarkService)
        let islandActivityCoordinator = IslandActivityCoordinator()
        let islandModuleRegistry = IslandModuleRegistry()
        let islandTimerStore = IslandTimerStore(defaults: settings.defaultsStore)
        let powerSourceMonitor = PowerSourceMonitor(
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded && islandActivityCoordinator.selectedModule == .battery
            },
            fullChargeAlertEnabled: { settings.islandFullChargeAlertEnabled }
        )
        let nowPlayingModuleStore = NowPlayingModuleStore(
            sourceFactory: { NowPlayingSourceFactory.bundled(isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded && islandActivityCoordinator.selectedModule == .media
            }) }
        )
        let systemStatusModuleStore = SystemStatusModuleStore(
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .system
            }
        )
        let aiUsageModuleStore = AIUsageModuleStore(
            makeProvider: { TokenTrackerClient(port: settings.aiUsageServerPort) },
            isSelectedAndExpanded: {
                islandActivityCoordinator.surfaceState.isExpanded
                    && islandActivityCoordinator.selectedModule == .aiUsage
            },
            compactMetric: { settings.aiUsageCompactMetric },
            alertsEnabled: { settings.aiUsageLimitAlertsEnabled }
        )
        let favoriteFoldersStore = FavoriteFoldersStore(
            persistence: FavoriteFoldersPersistenceController(),
            bookmarkService: bookmarkService
        )
        let favoriteFolderDropCoordinator = FavoriteFolderDropCoordinator(folders: favoriteFoldersStore,
                                                                          bookmarks: bookmarkService)
        let shelfRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .shelf)!
        )
        let transfersModuleRuntime = TransfersModuleRuntime(
            transferStore: transferStore
        )
        // Recording belongs to the app lifecycle, independently of Island.
        let clipboardRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .clipboard)!
        )
        let timerModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: islandTimerStore.descriptor,
            start: { islandTimerStore.start() },
            stop: { islandTimerStore.stop() }
        )
        let batteryModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: powerSourceMonitor.descriptor,
            start: { powerSourceMonitor.start() },
            stop: { powerSourceMonitor.stop() }
        )
        let mediaModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: nowPlayingModuleStore.descriptor,
            start: { nowPlayingModuleStore.start() },
            stop: { nowPlayingModuleStore.stop() }
        )
        let favoriteFoldersModuleRuntime = CallbackIslandModuleRuntime(
            descriptor: islandModuleRegistry.descriptor(for: .folders)!,
            start: { favoriteFoldersStore.start() },
            stop: { favoriteFoldersStore.stop(); favoriteFolderDropCoordinator.cancelCopy() }
        )
        self.islandActivityCoordinator = islandActivityCoordinator
        self.islandModuleRegistry = islandModuleRegistry
        self.islandTimerStore = islandTimerStore
        self.powerSourceMonitor = powerSourceMonitor
        self.nowPlayingModuleStore = nowPlayingModuleStore
        self.systemStatusModuleStore = systemStatusModuleStore
        self.aiUsageModuleStore = aiUsageModuleStore
        self.favoriteFoldersStore = favoriteFoldersStore
        self.favoriteFolderDropCoordinator = favoriteFolderDropCoordinator
        self.transfersModuleRuntime = transfersModuleRuntime
        self.timerModuleRuntime = timerModuleRuntime
        self.batteryModuleRuntime = batteryModuleRuntime
        self.mediaModuleRuntime = mediaModuleRuntime
        self.favoriteFoldersModuleRuntime = favoriteFoldersModuleRuntime
        self.islandModuleContainer = IslandModuleContainer(
            registrations: [
                IslandModuleRegistration(
                    descriptor: clipboardRuntime.descriptor,
                    runtime: clipboardRuntime,
                    makeContentView: { _ in AnyView(ClipboardHistoryView(isIsland: true)) }
                ),
                IslandModuleRegistration(
                    descriptor: shelfRuntime.descriptor,
                    runtime: shelfRuntime,
                    makeContentView: { _ in AnyView(IslandShelfModuleView()) }
                ),
                IslandModuleRegistration(
                    descriptor: transfersModuleRuntime.descriptor,
                    runtime: transfersModuleRuntime,
                    makeContentView: { context in
                        AnyView(IslandTransfersView(
                            onPerformRecovery: context.onPerformRecovery
                        ))
                    }
                ),
                IslandModuleRegistration(
                    descriptor: timerModuleRuntime.descriptor,
                    runtime: timerModuleRuntime,
                    makeContentView: { _ in AnyView(IslandModuleScrollView { IslandTimerView() }) }
                ),
                IslandModuleRegistration(
                    descriptor: batteryModuleRuntime.descriptor,
                    runtime: batteryModuleRuntime,
                    makeContentView: { _ in AnyView(IslandModuleScrollView { IslandBatteryView() }) }
                ),
                IslandModuleRegistration(
                    descriptor: systemStatusModuleStore.descriptor,
                    runtime: systemStatusModuleStore,
                    makeContentView: { _ in AnyView(IslandSystemStatusView()) }
                ),
                IslandModuleRegistration(
                    descriptor: mediaModuleRuntime.descriptor,
                    runtime: mediaModuleRuntime,
                    makeContentView: { _ in
                        AnyView(IslandModuleScrollView(fillsViewport: true) { IslandNowPlayingView() })
                    }
                ),
                IslandModuleRegistration(
                    descriptor: favoriteFoldersModuleRuntime.descriptor,
                    runtime: favoriteFoldersModuleRuntime,
                    makeContentView: { _ in AnyView(FavoriteFoldersModuleView()) }
                ),
                IslandModuleRegistration(
                    descriptor: aiUsageModuleStore.descriptor,
                    runtime: aiUsageModuleStore,
                    makeContentView: { _ in AnyView(IslandModuleScrollView { IslandAIUsageView() }) }
                ),
            ],
            coordinator: islandActivityCoordinator
        )
        islandTimerStore.onActivity = { [weak self] activity in
            self?.timerModuleRuntime.replaceActivity(activity)
            if activity?.priority == .timerFinished,
               let self,
               self.settings.islandEnabled,
               self.islandActivityCoordinator.surfaceState != .pinned {
                self.islandActivityCoordinator.show(module: .timer)
            }
        }
        powerSourceMonitor.onActivity = { [weak self] activity in
            self?.batteryModuleRuntime.replaceActivity(activity)
        }
        favoriteFolderDropCoordinator.onActivity = { [weak self] activity in
            self?.favoriteFoldersModuleRuntime.replaceActivity(activity)
        }
        nowPlayingModuleStore.onActivity = { [weak self] activity in
            self?.mediaModuleRuntime.replaceActivity(activity)
        }
    }
}
