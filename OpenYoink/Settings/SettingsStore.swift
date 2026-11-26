import Foundation
import OpenYoinkModuleCore

/// UserDefaults-backed app settings, observable by SwiftUI.
///
/// All keys are prefixed with `OpenYoink.` to avoid collisions. Defaults are
/// registered on init, so reads always return meaningful values. Trigger
/// settings are consumed by `HotKeyMonitor` / `MouseShakeMonitor` /
/// `EdgeTriggerMonitor`; the settings UI lives in `SettingsView`.
@MainActor
@Observable
final class SettingsStore {
    // MARK: - Value types

    /// Screen edge the shelf attaches to, or free placement (custom).
    enum ShelfPosition: String, CaseIterable, Sendable {
        case left, right
        /// Free placement: the panel is dragged by its title-bar area and
        /// the frame persists in `customShelfFrame`.
        case custom
    }

    /// Which surface presents the same shelf data. Classic retains the
    /// existing left/right/custom panel; Island anchors a compact surface to
    /// the camera housing (or a floating top pill on displays without one).
    enum ShelfPresentationMode: String, CaseIterable, Sendable {
        case classic, island
    }

    /// Which shelf surface the global shelf command controls when both are
    /// available. Availability is still governed by the independent surface
    /// toggles below; this value is only a preference and never disables a
    /// surface by itself.
    enum PreferredShelfSurface: String, CaseIterable, Sendable {
        case classic, island
    }

    /// Stable Island placement across multiple displays. `.main` follows the
    /// display designated as main in System Settings, `.automatic` preserves
    /// the legacy pointer/drag-following behavior, and `.display` pins one
    /// physical display using its ColorSync UUID.
    enum IslandDisplayTarget: Hashable, Sendable {
        case main
        case automatic
        case display(String)

        var persistedValue: String {
            switch self {
            case .main: "main"
            case .automatic: "automatic"
            case let .display(id): "display:\(id)"
            }
        }

        fileprivate init(persistedValue: String?) {
            guard let persistedValue else {
                self = .main
                return
            }
            if persistedValue == "automatic" {
                self = .automatic
            } else if persistedValue == "main" {
                self = .main
            } else if persistedValue.hasPrefix("display:") {
                let id = String(persistedValue.dropFirst("display:".count))
                self = id.isEmpty ? .main : .display(id)
            } else {
                self = .main
            }
        }
    }

    /// User-facing placement picker. Keeping this separate from
    /// `ShelfPosition` prevents Island from leaking into edge-only layout and
    /// trigger switches while still presenting one simple control in Settings.
    enum ShelfPlacement: String, CaseIterable, Sendable {
        case left, right, island, custom
    }

    /// What happens to an item after it is dragged out of the shelf.
    enum DragOutRemovalPolicy: String, CaseIterable, Sendable {
        case keep   // keep the item on the shelf
        case remove // remove it after a successful drop
        case ask    // ask every time (NSAlert in DragSessionController)
    }

    /// UI language override.
    enum LanguagePreference: String, CaseIterable, Sendable {
        case system, chinese, english
    }

    /// What happens when the user starts dragging with the left mouse button
    /// held.
    enum DragAutoAppearMode: String, CaseIterable, Sendable {
        /// Show the shelf at its configured position as soon as a drag starts.
        case immediate
        /// Stay hidden on drag start; reveal when the drag rests at the
        /// shelf's screen edge (drag version of the edge trigger).
        case edgeOnly
        /// No drag-triggered appearance.
        case off
    }

    /// Codable description of the global toggle hot key. Consumed by
    /// `HotKeyMonitor`, which maps it to Carbon modifiers; the
    /// `ShortcutRecorderView` writes new values (and clears to nil).
    struct HotKeyShortcut: Codable, Equatable, Sendable {
        /// Hardware-independent virtual key code (kVK_*; 49 = Space).
        var keyCode: UInt32
        var command: Bool
        var shift: Bool
        var option: Bool
        var control: Bool

        /// ⌘⇧Space
        static let `default` = HotKeyShortcut(
            keyCode: 49, command: true, shift: true, option: false, control: false
        )
    }

    // MARK: - General

    var appearance: ShelfAppearance {
        didSet {
            let normalized = appearance.normalized()
            if normalized != appearance {
                appearance = normalized
            }
            if let data = try? JSONEncoder().encode(normalized) {
                save(data, forKey: SettingsKeys.appearance)
            }
        }
    }

    func resetAppearance() { appearance = .default }

    var clipboardHistoryEnabled: Bool {
        didSet { save(clipboardHistoryEnabled, forKey: SettingsKeys.clipboardHistoryEnabled) }
    }

    var clipboardHistoryPaused: Bool {
        didSet { save(clipboardHistoryPaused, forKey: SettingsKeys.clipboardHistoryPaused) }
    }

    var clipboardHistoryRetentionDays: Int {
        didSet { save(clipboardHistoryRetentionDays, forKey: SettingsKeys.clipboardHistoryRetentionDays) }
    }

    var clipboardHistoryEntryLimit: Int {
        didSet { save(clipboardHistoryEntryLimit, forKey: SettingsKeys.clipboardHistoryEntryLimit) }
    }
    var clipboardHistoryShortcut: HotKeyShortcut? {
        didSet {
            if let data = try? JSONEncoder().encode(clipboardHistoryShortcut) {
                save(data, forKey: SettingsKeys.clipboardHistoryShortcut)
            }
        }
    }

    /// Edge the shelf attaches to. Default: right.
    var shelfPosition: ShelfPosition {
        didSet { save(shelfPosition.rawValue, forKey: SettingsKeys.shelfPosition) }
    }

    /// The side shelf and Island are independent surfaces over one ShelfStore.
    /// New installs enable both surfaces and start with Island as the preferred
    /// entry point. Migration below keeps existing users' explicit choices.
    var classicShelfEnabled: Bool {
        didSet { save(classicShelfEnabled, forKey: SettingsKeys.classicShelfEnabled) }
    }

    var islandEnabled: Bool {
        didSet { save(islandEnabled, forKey: SettingsKeys.islandEnabled) }
    }

    var islandDisplayTarget: IslandDisplayTarget {
        didSet {
            save(islandDisplayTarget.persistedValue,
                         forKey: SettingsKeys.islandDisplayTarget)
        }
    }

    /// Shelf is an optional Island module. Turning it off never deletes shelf
    /// contents and doesn't affect the side shelf.
    var islandShelfEnabled: Bool {
        get { islandModuleConfiguration.isEnabled(.shelf) }
        set { setIslandModuleEnabled(newValue, id: .shelf) }
    }

    var preferredShelfSurface: PreferredShelfSurface {
        didSet {
            save(preferredShelfSurface.rawValue,
                         forKey: SettingsKeys.preferredShelfSurface)
        }
    }

    /// Resolves the user's preferred shelf against currently enabled
    /// surfaces. The stored preference is intentionally retained while its
    /// surface is disabled, so re-enabling it restores the previous choice.
    var effectivePreferredShelfSurface: PreferredShelfSurface? {
        let islandShelfAvailable = islandEnabled && islandShelfEnabled
        // The established global "Shelf" command belongs to the side shelf
        // whenever that surface is enabled. Island remains independently
        // clickable and drag-addressable; it is only the shortcut fallback
        // when the side shelf is disabled.
        if classicShelfEnabled { return .classic }
        if islandShelfAvailable { return .island }
        return nil
    }

    /// Compatibility façade for pre-dual-surface call sites and stored
    /// preferences. New code must use the independent booleans above.
    var shelfPresentationMode: ShelfPresentationMode {
        get {
            effectivePreferredShelfSurface == .island ? .island : .classic
        }
        set {
            switch newValue {
            case .classic:
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .island:
                classicShelfEnabled = false
                islandEnabled = true
                islandShelfEnabled = true
                preferredShelfSurface = .island
            }
        }
    }

    /// Combined Settings binding. Selecting Island preserves the last classic
    /// position so switching back restores the user's previous layout.
    var shelfPlacement: ShelfPlacement {
        get {
            if shelfPresentationMode == .island { return .island }
            switch shelfPosition {
            case .left: return .left
            case .right: return .right
            case .custom: return .custom
            }
        }
        set {
            switch newValue {
            case .island:
                classicShelfEnabled = false
                islandEnabled = true
                islandShelfEnabled = true
                preferredShelfSurface = .island
            case .left:
                shelfPosition = .left
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .right:
                shelfPosition = .right
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            case .custom:
                shelfPosition = .custom
                classicShelfEnabled = true
                islandEnabled = false
                preferredShelfSurface = .classic
            }
        }
    }

    /// Optional hover reveal. Click, drag approach and the global shortcut are
    /// always available, so disabling hover never makes Island unreachable.
    var islandHoverRevealEnabled: Bool {
        didSet { save(islandHoverRevealEnabled, forKey: SettingsKeys.islandHoverRevealEnabled) }
    }

    /// Expands the Island Shelf when a drag approaches the top-center target.
    /// Off by default so browser tab rearrangement near the menu bar remains
    /// unobstructed; the side shelf keeps its independent edge-drag behavior.
    var islandDragApproachEnabled: Bool {
        didSet {
            save(islandDragApproachEnabled,
                         forKey: SettingsKeys.islandDragApproachEnabled)
        }
    }

    var islandTimerEnabled: Bool {
        get { islandModuleConfiguration.isEnabled(.timer) }
        set { setIslandModuleEnabled(newValue, id: .timer) }
    }

    var islandBatteryEnabled: Bool {
        get { islandModuleConfiguration.isEnabled(.battery) }
        set { setIslandModuleEnabled(newValue, id: .battery) }
    }

    var islandFullChargeAlertEnabled: Bool {
        didSet {
            save(islandFullChargeAlertEnabled,
                         forKey: SettingsKeys.islandFullChargeAlertEnabled)
        }
    }

    /// AI usage module (data from TokenTracker): the number shown in the
    /// compact Island while the module is enabled.
    var aiUsageCompactMetric: AIUsageCompactMetric {
        didSet { save(aiUsageCompactMetric.rawValue, forKey: SettingsKeys.aiUsageCompactMetric) }
    }

    /// Island alert when a plan limit crosses 80% / 95%.
    var aiUsageLimitAlertsEnabled: Bool {
        didSet { save(aiUsageLimitAlertsEnabled, forKey: SettingsKeys.aiUsageLimitAlertsEnabled) }
    }

    /// TokenTracker's local API port. No UI: only changes for a custom
    /// `tokentracker serve --port`.
    var aiUsageServerPort: Int {
        didSet { save(aiUsageServerPort, forKey: SettingsKeys.aiUsageServerPort) }
    }

    /// Displays without a notch: what the collapsed Island shows while idle,
    /// so the floating pill doesn't sit on top of other apps' toolbars.
    var islandFloatingIdleStyle: IslandFloatingIdleStyle {
        didSet { save(islandFloatingIdleStyle.rawValue, forKey: SettingsKeys.islandFloatingIdleStyle) }
    }

    /// Optional local Now Playing module. It remains opt-in so a fallback
    /// player never requests Automation access until the user asks for media
    /// controls, while the UI itself is a first-class Island module.
    var islandMediaEnabled: Bool {
        get { islandModuleConfiguration.isEnabled(.media) }
        set { setIslandModuleEnabled(newValue, id: .media) }
    }

    /// Versioned primary configuration for Island module enablement and the
    /// five user-controlled pinned positions. Legacy module flags remain downgrade
    /// keys for one release so downgrading does not discard user choices.
    var islandModuleConfiguration: IslandModuleConfiguration {
        didSet {
            persistIslandModuleConfiguration()
            writeLegacyModuleKeys()
        }
    }

    func isIslandModuleEnabled(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isEnabled(id)
    }

    func isIslandModulePinned(_ id: IslandModuleID) -> Bool {
        islandModuleConfiguration.isPinned(id)
    }

    func setIslandModuleEnabled(_ enabled: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setEnabled(enabled, for: id)
        islandModuleConfiguration = configuration
    }

    func setIslandModulePinned(_ pinned: Bool, id: IslandModuleID) {
        var configuration = islandModuleConfiguration
        configuration.setPinned(pinned, for: id)
        islandModuleConfiguration = configuration
    }

    func movePinnedIslandModules(fromOffsets: IndexSet, toOffset: Int) {
        var configuration = islandModuleConfiguration
        configuration.movePinned(fromOffsets: fromOffsets, toOffset: toOffset)
        islandModuleConfiguration = configuration
    }

    /// Shelf width in points. Default: 320.
    var shelfWidth: Double {
        didSet { save(shelfWidth, forKey: SettingsKeys.shelfWidth) }
    }

    /// Hide the shelf automatically after a drag-out. Default: false.
    var autoHide: Bool {
        didSet { save(autoHide, forKey: SettingsKeys.autoHide) }
    }

    /// Keep an automatically revealed side shelf open after a successful
    /// drag-in. This deliberately affects only the drag-in completion path:
    /// drag-out and empty-shelf auto-hide retain their own settings.
    /// Default: true, preserving successful-drop behavior for existing users.
    var keepShelfOpenAfterDrop: Bool {
        didSet { save(keepShelfOpenAfterDrop, forKey: SettingsKeys.keepShelfOpenAfterDrop) }
    }

    /// hide the shelf automatically when its items go from non-empty to
    /// empty (removal / drag-out). A shelf explicitly summoned while empty
    /// stays put — the rule only fires on the non-empty → empty transition.
    /// Default: true.
    var autoHideWhenEmpty: Bool {
        didSet { save(autoHideWhenEmpty, forKey: SettingsKeys.autoHideWhenEmpty) }
    }

    /// What happens after an item is dragged out. Default: keep.
    var dragOutRemovalPolicy: DragOutRemovalPolicy {
        didSet { save(dragOutRemovalPolicy.rawValue, forKey: SettingsKeys.dragOutRemovalPolicy) }
    }

    /// UI language override. Default: system.
    var language: LanguagePreference {
        didSet { save(language.rawValue, forKey: SettingsKeys.language) }
    }

    var autoUpdateCheckEnabled: Bool {
        didSet { save(autoUpdateCheckEnabled, forKey: SettingsKeys.autoUpdateCheckEnabled) }
    }

    var onboardingVersion: Int {
        didSet { save(onboardingVersion, forKey: SettingsKeys.onboardingVersion) }
    }

    /// Whether `onboardingVersion` was actually persisted at launch. It is
    /// never registered as a default, which tells fresh installs apart.
    let hadPersistedOnboardingVersion: Bool

    /// EdgeTab: vertical placement of the shelf (and its edge tab) along the
    /// attached edge — 0 pins to the bottom of the visible area, 1 to the top.
    /// Default: 0.5 (vertically centered, matching the pre-EdgeTab look).
    /// No "unset" state needs distinguishing, so it lives in register(defaults:).
    var shelfEdgeOffset: Double {
        didSet { save(shelfEdgeOffset, forKey: SettingsKeys.shelfEdgeOffset) }
    }

    /// EdgeTab: show the edge tab on the shelf's screen edge while the shelf
    /// is hidden (mutually exclusive model — the tab disappears once the shelf
    /// opens; collapsing is done via the shelf's own outer-edge hot zone or
    /// inner chevron handle). Only meaningful for left/right positions —
    /// custom placement has no attachment edge, so no tab is shown.
    /// Default: true.
    var edgeTabEnabled: Bool {
        didSet { save(edgeTabEnabled, forKey: SettingsKeys.edgeTabEnabled) }
    }

    var edgeTabIconVisible: Bool {
        didSet { save(edgeTabIconVisible, forKey: SettingsKeys.edgeTabIconVisible) }
    }

    var edgeTabIconSize: Double {
        didSet {
            let normalized = Self.normalizedEdgeTabIconSize(edgeTabIconSize)
            if normalized != edgeTabIconSize { edgeTabIconSize = normalized }
            save(normalized, forKey: SettingsKeys.edgeTabIconSize)
        }
    }

    nonisolated static let edgeTabIconSizeRange: ClosedRange<Double> = 6...10
    nonisolated static let defaultEdgeTabIconSize: Double = 10

    nonisolated static func normalizedEdgeTabIconSize(_ size: Double) -> Double {
        size.isFinite
            ? min(edgeTabIconSizeRange.upperBound, max(edgeTabIconSizeRange.lowerBound, size))
            : defaultEdgeTabIconSize
    }

    /// Persisted panel frame for the `custom` shelf position, in global
    /// screen coordinates. nil = no custom placement yet — the first switch to
    /// custom starts from the right-edge default frame (see
    /// `ShelfLayoutEngine.targetFrame`). Readers must re-validate against the
    /// current screens (`ShelfLayoutEngine.validatedCustomFrame`): the screen
    /// the frame lived on may have been unplugged.
    var customShelfFrame: CGRect? {
        didSet {
            if let customShelfFrame, let data = try? JSONEncoder().encode(customShelfFrame) {
                save(data, forKey: SettingsKeys.customShelfFrame)
            } else if customShelfFrame == nil {
                save(nil, forKey: SettingsKeys.customShelfFrame)
            }
        }
    }

    // MARK: - Triggers

    /// Global hot key (⌘⇧Space) toggles the shelf. Default: true.
    var hotKeyEnabled: Bool {
        didSet { save(hotKeyEnabled, forKey: SettingsKeys.hotKeyEnabled) }
    }

    /// Mouse-shake gesture shows the shelf. Default: false (off until the
    /// gesture is enabled in Settings).
    var shakeTriggerEnabled: Bool {
        didSet { save(shakeTriggerEnabled, forKey: SettingsKeys.shakeTriggerEnabled) }
    }

    /// Compatibility preference for releases that used the original edge trigger.
    var edgeTriggerEnabled: Bool {
        get { defaults.bool(forKey: SettingsKeys.edgeTriggerEnabled) }
        set { defaults.set(newValue, forKey: SettingsKeys.edgeTriggerEnabled) }
    }

    /// drag-triggered shelf appearance. Default: `.edgeOnly`, so starting
    /// a drag does not cover content before the pointer approaches the shelf.
    /// `.edgeOnly` requires a non-custom shelf position (no attachment edge
    /// otherwise); `custom` position pauses the edge mechanism while active.
    var dragAutoAppearMode: DragAutoAppearMode {
        didSet { save(dragAutoAppearMode.rawValue, forKey: SettingsKeys.dragAutoAppearMode) }
    }

    /// double-pressing the global hot key saves the general pasteboard
    /// to the shelf. While enabled, a single press toggles the shelf after a
    /// short (~0.3 s) discrimination delay; disabling it restores zero-latency
    /// single presses. Default: true.
    var hotKeyDoublePressSavesClipboard: Bool {
        didSet { save(hotKeyDoublePressSavesClipboard, forKey: SettingsKeys.hotKeyDoublePressSavesClipboard) }
    }

    /// Shake sensitivity (three tiers; higher = triggers more easily).
    /// Default: medium. Mapped to heuristic parameters by
    /// `TriggerSensitivity.shakeParameters`.
    var shakeSensitivity: TriggerSensitivity {
        didSet { save(shakeSensitivity.rawValue, forKey: SettingsKeys.shakeSensitivity) }
    }

    /// Edge-trigger sensitivity (three tiers; higher = shorter dwell time and
    /// wider band). Default: medium. Mapped by `TriggerSensitivity.edgeDwellTime`
    /// / `.edgeBandWidth`.
    var edgeTriggerSensitivity: TriggerSensitivity {
        didSet { save(edgeTriggerSensitivity.rawValue, forKey: SettingsKeys.edgeTriggerSensitivity) }
    }

    /// The toggle hot key, or nil when the user cleared it in the recorder
    /// (no shortcut assigned; `hotKeyEnabled` stays untouched so re-recording
    /// a shortcut re-arms the monitor without a separate toggle).
    ///
    /// Persisted as JSON. Three persisted states: key absent → `.default`
    /// (fresh install); JSON `null` → explicitly cleared; object → shortcut.
    var hotKeyShortcut: HotKeyShortcut? {
        didSet {
            // Encoding the Optional itself: a cleared shortcut persists as
            // top-level `null`, distinguishing it from "never customized".
            if let data = try? JSONEncoder().encode(hotKeyShortcut) {
                save(data, forKey: SettingsKeys.hotKeyShortcut)
            }
        }
    }

    // MARK: - Ignore list

    /// Bundle identifiers of apps in which shake/edge triggers stay silent.
    var ignoredAppBundleIDs: [String] {
        didSet { save(ignoredAppBundleIDs, forKey: SettingsKeys.ignoredAppBundleIDs) }
    }

    /// Adds a bundle ID to the ignore list in Settings. Trims
    /// whitespace and dedupes case-insensitively, mirroring the matching
    /// rules of `IgnoreListService.isIgnored`.
    func addIgnoredApp(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isDuplicate = ignoredAppBundleIDs.contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !isDuplicate else { return }
        ignoredAppBundleIDs.append(trimmed)
    }

    /// Removes entries from the ignore list in Settings.
    func removeIgnoredApps(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty else { return }
        ignoredAppBundleIDs.removeAll { bundleIDs.contains($0) }
    }

    // MARK: - Init

    private let defaults: UserDefaults
    @ObservationIgnored private var changeHandler: (@MainActor () -> Void)?
    @ObservationIgnored private var isChangeDeliveryScheduled = false

    func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        changeHandler = handler
    }

    private func save(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        guard !isChangeDeliveryScheduled, changeHandler != nil else { return }
        isChangeDeliveryScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            isChangeDeliveryScheduled = false
            changeHandler?()
        }
    }

    /// Shared persistence domain for feature stores that must follow the
    /// isolated UI-test/defaults suite instead of silently using `.standard`.
    var defaultsStore: UserDefaults { defaults }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func read<Value: RawRepresentable>(_ type: Value.Type, _ key: String, fallback: Value) -> Value
        where Value.RawValue == String {
            defaults.string(forKey: key).flatMap(Value.init(rawValue:)) ?? fallback
        }

        hadPersistedOnboardingVersion = defaults.object(forKey: SettingsKeys.onboardingVersion) != nil
        let persistedModuleConfigurationData = defaults.data(
            forKey: SettingsKeys.islandModuleConfiguration
        )
        // Registration defaults are process-wide and leak into isolated test
        // suites. Only durable migration evidence may classify an install as
        // existing. Established installs have an onboarding version, while earlier modular
        // builds may only have the versioned configuration blob.
        let hadPersistedAppSettings = hadPersistedOnboardingVersion || persistedModuleConfigurationData != nil
        let migration = SettingsMigration(defaults: defaults)
        defaults.register(defaults: SettingsKeys.registeredDefaults)

        clipboardHistoryEnabled = defaults.bool(forKey: SettingsKeys.clipboardHistoryEnabled)
        clipboardHistoryPaused = defaults.bool(forKey: SettingsKeys.clipboardHistoryPaused)
        let retentionDays = defaults.integer(forKey: SettingsKeys.clipboardHistoryRetentionDays)
        clipboardHistoryRetentionDays = [1, 7, 30].contains(retentionDays) ? retentionDays : 7
        let entryLimit = defaults.integer(forKey: SettingsKeys.clipboardHistoryEntryLimit)
        clipboardHistoryEntryLimit = ClipboardHistoryPolicy.supportedEntryLimits.contains(entryLimit) ? entryLimit : 30
        if let data = defaults.data(forKey: SettingsKeys.clipboardHistoryShortcut) {
            clipboardHistoryShortcut = (try? JSONDecoder().decode(HotKeyShortcut?.self, from: data)) ?? nil
        } else {
            clipboardHistoryShortcut = HotKeyShortcut(keyCode: 9, command: true, shift: true, option: false, control: false)
        }
        shelfPosition = read(ShelfPosition.self, SettingsKeys.shelfPosition, fallback: .right)
        let surfaces = migration.resolveSurfaces(hadOnboarding: hadPersistedOnboardingVersion)
        classicShelfEnabled = surfaces.classic
        islandEnabled = surfaces.island
        islandDisplayTarget = IslandDisplayTarget(
            persistedValue: defaults.string(forKey: SettingsKeys.islandDisplayTarget)
        )
        preferredShelfSurface = surfaces.preferred
        let resolvedIslandHoverRevealEnabled = defaults.bool(
            forKey: SettingsKeys.islandHoverRevealEnabled
        )
        let resolvedIslandDragApproachEnabled = defaults.bool(
            forKey: SettingsKeys.islandDragApproachEnabled
        )
        let resolvedIslandTimerEnabled = defaults.bool(forKey: SettingsKeys.islandTimerEnabled)
        let resolvedIslandBatteryEnabled = defaults.bool(forKey: SettingsKeys.islandBatteryEnabled)
        let resolvedIslandFullChargeAlertEnabled = defaults.bool(
            forKey: SettingsKeys.islandFullChargeAlertEnabled
        )
        let resolvedIslandMediaEnabled = defaults.bool(forKey: SettingsKeys.islandMediaEnabled)
        islandHoverRevealEnabled = resolvedIslandHoverRevealEnabled
        islandDragApproachEnabled = resolvedIslandDragApproachEnabled
        islandFullChargeAlertEnabled = resolvedIslandFullChargeAlertEnabled
        aiUsageCompactMetric = defaults.string(forKey: SettingsKeys.aiUsageCompactMetric)
            .flatMap(AIUsageCompactMetric.init(rawValue:)) ?? .todayCost
        aiUsageLimitAlertsEnabled = defaults.bool(forKey: SettingsKeys.aiUsageLimitAlertsEnabled)
        let storedPort = defaults.integer(forKey: SettingsKeys.aiUsageServerPort)
        aiUsageServerPort = (1...65535).contains(storedPort) ? storedPort : TokenTrackerClient.defaultPort
        islandFloatingIdleStyle = defaults.string(forKey: SettingsKeys.islandFloatingIdleStyle)
            .flatMap(IslandFloatingIdleStyle.init(rawValue:)) ?? .dot
        islandModuleConfiguration = migration.resolveModules(
            configurationData: persistedModuleConfigurationData,
            existingInstallation: hadPersistedAppSettings,
            shelfEnabled: surfaces.shelf, timerEnabled: resolvedIslandTimerEnabled,
            batteryEnabled: resolvedIslandBatteryEnabled, mediaEnabled: resolvedIslandMediaEnabled
        )
        shelfWidth = defaults.double(forKey: SettingsKeys.shelfWidth)
        if let data = defaults.data(forKey: SettingsKeys.appearance),
           let decoded = try? JSONDecoder().decode(ShelfAppearance.self, from: data) {
            appearance = decoded.normalized()
        } else {
            appearance = .default
        }
        shelfEdgeOffset = defaults.double(forKey: SettingsKeys.shelfEdgeOffset)
        edgeTabEnabled = defaults.bool(forKey: SettingsKeys.edgeTabEnabled)
        edgeTabIconVisible = defaults.bool(forKey: SettingsKeys.edgeTabIconVisible)
        edgeTabIconSize = Self.normalizedEdgeTabIconSize(defaults.double(forKey: SettingsKeys.edgeTabIconSize))
        autoHide = defaults.bool(forKey: SettingsKeys.autoHide)
        keepShelfOpenAfterDrop = defaults.bool(forKey: SettingsKeys.keepShelfOpenAfterDrop)
        autoHideWhenEmpty = defaults.bool(forKey: SettingsKeys.autoHideWhenEmpty)
        dragOutRemovalPolicy = read(DragOutRemovalPolicy.self, SettingsKeys.dragOutRemovalPolicy, fallback: .keep)
        language = read(LanguagePreference.self, SettingsKeys.language, fallback: .system)
        autoUpdateCheckEnabled = defaults.bool(forKey: SettingsKeys.autoUpdateCheckEnabled)
        onboardingVersion = defaults.object(forKey: SettingsKeys.onboardingVersion) as? Int ?? 0
        if let data = defaults.data(forKey: SettingsKeys.customShelfFrame) {
            customShelfFrame = try? JSONDecoder().decode(CGRect.self, from: data)
        } else {
            customShelfFrame = nil
        }
        hotKeyEnabled = defaults.bool(forKey: SettingsKeys.hotKeyEnabled)
        hotKeyDoublePressSavesClipboard = defaults.bool(forKey: SettingsKeys.hotKeyDoublePressSavesClipboard)
        shakeTriggerEnabled = defaults.bool(forKey: SettingsKeys.shakeTriggerEnabled)
        dragAutoAppearMode = migration.resolveDragMode()
        shakeSensitivity = read(TriggerSensitivity.self, SettingsKeys.shakeSensitivity, fallback: .medium)
        edgeTriggerSensitivity = read(TriggerSensitivity.self, SettingsKeys.edgeTriggerSensitivity, fallback: .medium)
        if let data = defaults.data(forKey: SettingsKeys.hotKeyShortcut) {

            do {
                hotKeyShortcut = try JSONDecoder().decode(HotKeyShortcut?.self, from: data)
            } catch {
                hotKeyShortcut = .default
            }
        } else {
            hotKeyShortcut = .default
        }
        ignoredAppBundleIDs = defaults.stringArray(forKey: SettingsKeys.ignoredAppBundleIDs) ?? []
        // A valid primary configuration wins on every launch. Refresh the
        // legacy keys immediately, including when the user has never
        // changes a module in this process.
        writeLegacyModuleKeys()
    }

    private func persistIslandModuleConfiguration() {
        guard let data = try? JSONEncoder().encode(islandModuleConfiguration) else { return }
        save(data, forKey: SettingsKeys.islandModuleConfiguration)
    }

    private func writeLegacyModuleKeys() {
        for (key, module) in SettingsKeys.legacyModules {
            defaults.set(islandModuleConfiguration.isEnabled(module), forKey: key)
        }
    }
}
