import Foundation
import OpenYoinkModuleCore

@MainActor
struct SettingsMigration {
    private let defaults: UserDefaults
    private let legacyEdgeTriggerEnabled: Bool
    private let persistedDragMode: String?
    private let standardPersistentDomain: [String: Any]?
    private let persistedClassicShelfEnabled: Bool?
    private let persistedIslandEnabled: Bool?
    private let persistedIslandShelfEnabled: Bool?
    private let persistedPreferredSurface: String?
    private let legacyPresentationMode: SettingsStore.ShelfPresentationMode
    private let persistedSurfaceSettingsVersion: Int

    init(defaults: UserDefaults) {
        self.defaults = defaults

        legacyEdgeTriggerEnabled = defaults.bool(forKey: SettingsKeys.edgeTriggerEnabled)
        persistedDragMode = defaults.string(forKey: SettingsKeys.dragAutoAppearMode)
        // Preserve settings written by an earlier development build of the
        // dual-surface feature, which predates the explicit migration version.
        // Only inspect the app's real persistent domain for `.standard`;
        // isolated test/UI suites must not inherit the host app's preferences.
        let standardPersistentDomain: [String: Any]? = if defaults === UserDefaults.standard,
                                                          let domain = Bundle.main.bundleIdentifier {
            defaults.persistentDomain(forName: domain)
        } else {
            nil
        }
        persistedClassicShelfEnabled = standardPersistentDomain?[SettingsKeys.classicShelfEnabled]
            as? Bool ?? defaults.object(forKey: SettingsKeys.classicShelfEnabled) as? Bool
        persistedIslandEnabled = standardPersistentDomain?[SettingsKeys.islandEnabled]
            as? Bool ?? defaults.object(forKey: SettingsKeys.islandEnabled) as? Bool
        persistedIslandShelfEnabled = standardPersistentDomain?[SettingsKeys.islandShelfEnabled]
            as? Bool ?? defaults.object(forKey: SettingsKeys.islandShelfEnabled) as? Bool
        persistedPreferredSurface = standardPersistentDomain?[SettingsKeys.preferredShelfSurface]
            as? String ?? defaults.string(forKey: SettingsKeys.preferredShelfSurface)
        let persistedLegacyPresentationMode = defaults.string(
            forKey: SettingsKeys.shelfPresentationMode
        ).flatMap(SettingsStore.ShelfPresentationMode.init(rawValue:))
        legacyPresentationMode = persistedLegacyPresentationMode ?? .classic
        persistedSurfaceSettingsVersion = defaults.integer(
            forKey: SettingsKeys.shelfSurfaceSettingsVersion
        )
        self.standardPersistentDomain = standardPersistentDomain
    }

    func resolveSurfaces(hadOnboarding: Bool)
        -> (classic: Bool, island: Bool, shelf: Bool, preferred: SettingsStore.PreferredShelfSurface) {
        let hasPreversionedSurfaceSettings = standardPersistentDomain?[SettingsKeys.classicShelfEnabled] != nil
            || standardPersistentDomain?[SettingsKeys.islandEnabled] != nil
            || standardPersistentDomain?[SettingsKeys.islandShelfEnabled] != nil
            || standardPersistentDomain?[SettingsKeys.preferredShelfSurface] != nil
        let needsSurfaceMigration = persistedSurfaceSettingsVersion < 1
            && !hasPreversionedSurfaceSettings
        let resolvedClassicShelfEnabled: Bool
        let resolvedIslandEnabled: Bool
        let resolvedIslandShelfEnabled: Bool
        let resolvedPreferredSurface: SettingsStore.PreferredShelfSurface
        if needsSurfaceMigration {
            // Registration-domain defaults are process-wide, so a pristine
            // isolated UserDefaults suite can still appear to contain the
            // legacy `.classic` value after another SettingsStore is created.
            // An actual legacy Island choice still overrides that value, while
            // onboarding persistence identifies an established classic user.
            let isFreshInstall = !hadOnboarding
                && legacyPresentationMode != .island
            if isFreshInstall {
                resolvedClassicShelfEnabled = true
                resolvedIslandEnabled = true
                resolvedIslandShelfEnabled = true
                resolvedPreferredSurface = .island
            } else {
                resolvedClassicShelfEnabled = legacyPresentationMode == .classic
                resolvedIslandEnabled = legacyPresentationMode == .island
                resolvedIslandShelfEnabled = true
                resolvedPreferredSurface = legacyPresentationMode == .island
                    ? .island : .classic
            }
        } else {
            resolvedClassicShelfEnabled = persistedClassicShelfEnabled
                ?? defaults.bool(forKey: SettingsKeys.classicShelfEnabled)
            resolvedIslandEnabled = persistedIslandEnabled
                ?? defaults.bool(forKey: SettingsKeys.islandEnabled)
            resolvedIslandShelfEnabled = persistedIslandShelfEnabled
                ?? defaults.bool(forKey: SettingsKeys.islandShelfEnabled)
            resolvedPreferredSurface = SettingsStore.PreferredShelfSurface(
                rawValue: persistedPreferredSurface
                    ?? defaults.string(forKey: SettingsKeys.preferredShelfSurface)
                    ?? ""
            ) ?? .classic
        }
        if needsSurfaceMigration {
            defaults.set(resolvedClassicShelfEnabled, forKey: SettingsKeys.classicShelfEnabled)
            defaults.set(resolvedIslandEnabled, forKey: SettingsKeys.islandEnabled)
            defaults.set(resolvedIslandShelfEnabled, forKey: SettingsKeys.islandShelfEnabled)
            defaults.set(resolvedPreferredSurface.rawValue,
                         forKey: SettingsKeys.preferredShelfSurface)
        }
        if persistedSurfaceSettingsVersion < 1 {
            defaults.set(1, forKey: SettingsKeys.shelfSurfaceSettingsVersion)
        }
        return (resolvedClassicShelfEnabled, resolvedIslandEnabled, resolvedIslandShelfEnabled, resolvedPreferredSurface)
    }

    func resolveDragMode() -> SettingsStore.DragAutoAppearMode {
        if let persistedDragMode {
            return SettingsStore.DragAutoAppearMode(rawValue: persistedDragMode) ?? .edgeOnly
        }
        if legacyEdgeTriggerEnabled {
            defaults.set(SettingsStore.DragAutoAppearMode.edgeOnly.rawValue, forKey: SettingsKeys.dragAutoAppearMode)
        }
        return .edgeOnly
    }

    func resolveModules(configurationData: Data?, existingInstallation: Bool,
                        shelfEnabled: Bool, timerEnabled: Bool,
                        batteryEnabled: Bool, mediaEnabled: Bool) -> IslandModuleConfiguration {
        let migratedModuleConfiguration = Self.migratedModuleConfiguration(
            existingInstallation: existingInstallation,
            shelfEnabled: shelfEnabled,
            timerEnabled: timerEnabled,
            batteryEnabled: batteryEnabled,
            mediaEnabled: mediaEnabled
        )
        if let persistedModuleConfigurationData = configurationData {
            do {
                var decoded = try JSONDecoder().decode(
                    IslandModuleConfiguration.self,
                    from: persistedModuleConfigurationData
                )
                decoded.normalize()
                return decoded
            } catch {
                if defaults.data(forKey: SettingsKeys.islandModuleConfigurationCorruptBackup) == nil {
                    defaults.set(persistedModuleConfigurationData,
                                 forKey: SettingsKeys.islandModuleConfigurationCorruptBackup)
                }
                return migratedModuleConfiguration
            }
        } else {
            if let encoded = try? JSONEncoder().encode(migratedModuleConfiguration) {
                defaults.set(encoded, forKey: SettingsKeys.islandModuleConfiguration)
            }
            return migratedModuleConfiguration
        }
    }

    private static func migratedModuleConfiguration(
        existingInstallation: Bool,
        shelfEnabled: Bool,
        timerEnabled: Bool,
        batteryEnabled: Bool,
        mediaEnabled: Bool
    ) -> IslandModuleConfiguration {
        if !existingInstallation {
            return IslandModuleConfiguration(
                enabledModuleIDs: [.shelf, .transfers, .timer, .battery, .system],
                pinnedModuleIDs: [.shelf, .timer, .system]
            )
        }

        var enabled: [IslandModuleID] = []
        if shelfEnabled { enabled.append(.shelf) }
        if mediaEnabled { enabled.append(.media) }
        enabled.append(.transfers)
        if timerEnabled { enabled.append(.timer) }
        if batteryEnabled { enabled.append(.battery) }
        return IslandModuleConfiguration(
            enabledModuleIDs: enabled,
            pinnedModuleIDs: Array(enabled.prefix(
                IslandModuleConfiguration.maximumPinnedModules
            ))
        )
    }

}
