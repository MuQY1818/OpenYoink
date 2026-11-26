import OpenYoinkModuleCore

enum SettingsKeys {
    private static let prefix = "OpenYoink."
    static let appearance = prefix + "appearance.v1"
    static let shelfPosition = prefix + "shelfPosition"
    static let clipboardHistoryEnabled = prefix + "clipboardHistoryEnabled"
    static let clipboardHistoryPaused = prefix + "clipboardHistoryPaused"
    static let clipboardHistoryRetentionDays = prefix + "clipboardHistoryRetentionDays"
    static let clipboardHistoryEntryLimit = prefix + "clipboardHistoryEntryLimit"
    static let clipboardHistoryShortcut = prefix + "clipboardHistoryShortcut"
    static let shelfPresentationMode = prefix + "shelfPresentationMode"
    static let shelfSurfaceSettingsVersion = prefix + "shelfSurfaceSettingsVersion"
    static let classicShelfEnabled = prefix + "classicShelfEnabled"
    static let islandEnabled = prefix + "islandEnabled"
    static let islandDisplayTarget = prefix + "islandDisplayTarget"
    static let islandShelfEnabled = prefix + "islandShelfEnabled"
    static let preferredShelfSurface = prefix + "preferredShelfSurface"
    static let islandHoverRevealEnabled = prefix + "islandHoverRevealEnabled"
    static let islandDragApproachEnabled = prefix + "islandDragApproachEnabled"
    static let islandTimerEnabled = prefix + "islandTimerEnabled"
    static let islandBatteryEnabled = prefix + "islandBatteryEnabled"
    static let islandFullChargeAlertEnabled = prefix + "islandFullChargeAlertEnabled"
    static let islandMediaEnabled = prefix + "islandMediaEnabled"
    static let aiUsageCompactMetric = prefix + "aiUsageCompactMetric"
    static let islandFloatingIdleStyle = prefix + "islandFloatingIdleStyle"
    static let aiUsageLimitAlertsEnabled = prefix + "aiUsageLimitAlertsEnabled"
    static let aiUsageServerPort = prefix + "aiUsageServerPort"
    static let islandModuleConfiguration = prefix + "islandModuleConfiguration"
    static let islandModuleConfigurationCorruptBackup =
        prefix + "islandModuleConfigurationCorruptBackup"
    static let shelfWidth = prefix + "shelfWidth"
    static let shelfEdgeOffset = prefix + "shelfEdgeOffset"
    static let edgeTabEnabled = prefix + "edgeTabEnabled"
    static let edgeTabIconVisible = prefix + "edgeTabIconVisible"
    static let edgeTabIconSize = prefix + "edgeTabIconSize"
    static let autoHide = prefix + "autoHide"
    static let keepShelfOpenAfterDrop = prefix + "keepShelfOpenAfterDrop"
    static let autoHideWhenEmpty = prefix + "autoHideWhenEmpty"
    static let dragOutRemovalPolicy = prefix + "dragOutRemovalPolicy"
    static let language = prefix + "language"
    static let autoUpdateCheckEnabled = prefix + "autoUpdateCheckEnabled"
    static let onboardingVersion = prefix + "onboardingVersion"
    static let customShelfFrame = prefix + "customShelfFrame"
    static let hotKeyEnabled = prefix + "hotKeyEnabled"
    static let hotKeyDoublePressSavesClipboard = prefix + "hotKeyDoublePressSavesClipboard"
    static let shakeTriggerEnabled = prefix + "shakeTriggerEnabled"
    static let edgeTriggerEnabled = prefix + "edgeTriggerEnabled"
    static let dragAutoAppearMode = prefix + "dragAutoAppearMode"
    static let shakeSensitivity = prefix + "shakeSensitivity"
    static let edgeTriggerSensitivity = prefix + "edgeTriggerSensitivity"
    static let hotKeyShortcut = prefix + "hotKeyShortcut"
    static let ignoredAppBundleIDs = prefix + "ignoredAppBundleIDs"
    static let legacyModules: [(String, IslandModuleID)] = [
        (islandShelfEnabled, .shelf), (islandTimerEnabled, .timer),
        (islandBatteryEnabled, .battery), (islandMediaEnabled, .media),
    ]

    @MainActor
    static var registeredDefaults: [String: Any] { [
            clipboardHistoryEnabled: false,
            clipboardHistoryPaused: false,
            clipboardHistoryRetentionDays: 7,
            shelfPosition: SettingsStore.ShelfPosition.right.rawValue,
            shelfPresentationMode: SettingsStore.ShelfPresentationMode.classic.rawValue,
            classicShelfEnabled: true,
            islandEnabled: true,
            islandDisplayTarget: SettingsStore.IslandDisplayTarget.main.persistedValue,
            islandShelfEnabled: true,
            preferredShelfSurface: SettingsStore.PreferredShelfSurface.island.rawValue,
            islandHoverRevealEnabled: false,
            islandDragApproachEnabled: false,
            islandTimerEnabled: true,
            islandBatteryEnabled: true,
            islandFullChargeAlertEnabled: false,
            islandMediaEnabled: false,
            aiUsageCompactMetric: AIUsageCompactMetric.todayCost.rawValue,
            islandFloatingIdleStyle: IslandFloatingIdleStyle.dot.rawValue,
            aiUsageLimitAlertsEnabled: true,
            aiUsageServerPort: TokenTrackerClient.defaultPort,
            shelfWidth: 320.0,
            shelfEdgeOffset: 0.5,
            edgeTabEnabled: true,
            edgeTabIconVisible: true,
            edgeTabIconSize: SettingsStore.defaultEdgeTabIconSize,
            autoHide: false,
            keepShelfOpenAfterDrop: true,
            autoHideWhenEmpty: true,
            dragOutRemovalPolicy: SettingsStore.DragOutRemovalPolicy.keep.rawValue,
            language: SettingsStore.LanguagePreference.system.rawValue,
            autoUpdateCheckEnabled: true,
            hotKeyEnabled: true,
            hotKeyDoublePressSavesClipboard: true,
            shakeTriggerEnabled: false,
            edgeTriggerEnabled: false,
            shakeSensitivity: TriggerSensitivity.medium.rawValue,
            edgeTriggerSensitivity: TriggerSensitivity.medium.rawValue,
            ignoredAppBundleIDs: [String](),
    ] }
}
