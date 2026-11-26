import XCTest
@testable import OpenYoink

/// Trigger defaults and persistence in SettingsStore, and the mapping from
/// TriggerSensitivity to detector parameters.
@MainActor
final class TriggerSettingsTests: XCTestCase {
    // MARK: - Helpers

    /// A separate UserDefaults suite, so the app's own settings stay clean.
    private func makeSuite() throws -> (defaults: UserDefaults, name: String) {
        let name = "OpenYoinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    // MARK: - Sensitivity mappings

    func testShakeParameters_tiersGetStricterFromHighToLow() {
        let low = TriggerSensitivity.low.shakeParameters
        let medium = TriggerSensitivity.medium.shakeParameters
        let high = TriggerSensitivity.high.shakeParameters
        // Less sensitive: shorter window, more reversals, longer segments.
        XCTAssertLessThan(low.window, medium.window)
        XCTAssertLessThan(medium.window, high.window)
        XCTAssertGreaterThan(low.requiredReversals, medium.requiredReversals)
        XCTAssertGreaterThan(medium.requiredReversals, high.requiredReversals)
        XCTAssertGreaterThan(low.minSegmentDistance, medium.minSegmentDistance)
        XCTAssertGreaterThan(medium.minSegmentDistance, high.minSegmentDistance)
    }

    func testEdgeMappings_higherSensitivityMeansEasierTrigger() {
        XCTAssertGreaterThan(TriggerSensitivity.low.edgeDwellTime,
                             TriggerSensitivity.medium.edgeDwellTime)
        XCTAssertGreaterThan(TriggerSensitivity.medium.edgeDwellTime,
                             TriggerSensitivity.high.edgeDwellTime)
        XCTAssertLessThan(TriggerSensitivity.low.edgeBandWidth,
                          TriggerSensitivity.medium.edgeBandWidth)
        XCTAssertLessThan(TriggerSensitivity.medium.edgeBandWidth,
                          TriggerSensitivity.high.edgeBandWidth)
    }

    func testEdgeMappings_dragTunedValues() {
        // While dragging (left button held, at the edge) the dwell is shorter and
// the band wider than when hovering.
        XCTAssertEqual(TriggerSensitivity.low.edgeDwellTime, 0.4)
        XCTAssertEqual(TriggerSensitivity.medium.edgeDwellTime, 0.2)
        XCTAssertEqual(TriggerSensitivity.high.edgeDwellTime, 0.1)
        XCTAssertEqual(TriggerSensitivity.low.edgeBandWidth, 6)
        XCTAssertEqual(TriggerSensitivity.medium.edgeBandWidth, 10)
        XCTAssertEqual(TriggerSensitivity.high.edgeBandWidth, 16)
    }

    // MARK: - SettingsStore defaults & persistence

    func testDefaults_matchPlanRiskTable() throws {
        // Defaults: hot key on, shake and edge off, medium sensitivity.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.hotKeyEnabled)
        XCTAssertFalse(store.shakeTriggerEnabled)
        XCTAssertFalse(store.edgeTriggerEnabled)
        XCTAssertEqual(store.shakeSensitivity, .medium)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
        XCTAssertEqual(store.hotKeyShortcut, .default)
        XCTAssertEqual(store.ignoredAppBundleIDs, [])
        // Defaults: show at the edge while dragging, double-click saves the
// clipboard, hide an empty shelf.
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
        XCTAssertTrue(store.hotKeyDoublePressSavesClipboard)
        XCTAssertTrue(store.autoHideWhenEmpty)
    }

    func testTriggerSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.hotKeyEnabled = false
        store.shakeTriggerEnabled = true
        store.edgeTriggerEnabled = true
        store.shakeSensitivity = .high
        store.edgeTriggerSensitivity = .low
        store.hotKeyShortcut = SettingsStore.HotKeyShortcut(
            keyCode: 3, command: true, shift: false, option: true, control: false
        )
        store.ignoredAppBundleIDs = ["com.apple.safari"]

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.hotKeyEnabled)
        XCTAssertTrue(reloaded.shakeTriggerEnabled)
        XCTAssertTrue(reloaded.edgeTriggerEnabled)
        XCTAssertEqual(reloaded.shakeSensitivity, .high)
        XCTAssertEqual(reloaded.edgeTriggerSensitivity, .low)
        XCTAssertEqual(reloaded.hotKeyShortcut,
                       SettingsStore.HotKeyShortcut(keyCode: 3, command: true,
                                                    shift: false, option: true, control: false))
        XCTAssertEqual(reloaded.ignoredAppBundleIDs, ["com.apple.safari"])
    }

    func testLegacyDoubleSensitivity_fallsBackToMedium() throws {
        // An early version stored a Double; old or bad values fall back to medium without crashing.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(0.5, forKey: "OpenYoink.shakeSensitivity")
        defaults.set("garbage", forKey: "OpenYoink.edgeTriggerSensitivity")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.shakeSensitivity, .medium)
        XCTAssertEqual(store.edgeTriggerSensitivity, .medium)
    }

    func testUXSettings_persistAcrossInstances() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.dragAutoAppearMode = .edgeOnly
        store.hotKeyDoublePressSavesClipboard = false
        store.autoHideWhenEmpty = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
        XCTAssertFalse(reloaded.hotKeyDoublePressSavesClipboard)
        XCTAssertFalse(reloaded.autoHideWhenEmpty)
    }

    func testDragAutoAppearMode_invalidPersistedValue_fallsBackToEdgeOnly() throws {
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set("garbage", forKey: "OpenYoink.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_legacyEdgeTriggerEnabled_migratesToEdgeOnly() throws {
        // Migration: the old boolean edge trigger was on and the new mode was never
// persisted → .edgeOnly.
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "OpenYoink.edgeTriggerEnabled")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .edgeOnly)

        // The migration is written immediately: later instances read edgeOnly too.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.dragAutoAppearMode, .edgeOnly)
    }

    func testDragAutoAppearMode_explicitModeWinsOverLegacyFlag() throws {
        // Once the new mode was persisted the old boolean is ignored (migrates once).
        let (defaults, name) = try makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(true, forKey: "OpenYoink.edgeTriggerEnabled")
        defaults.set("off", forKey: "OpenYoink.dragAutoAppearMode")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dragAutoAppearMode, .off)
    }
}
