import XCTest
@testable import OpenYoink

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private func withStore(_ body: (SettingsStore, UserDefaults) throws -> Void) throws {
        let name = "OpenYoinkAppearanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(SettingsStore(defaults: defaults), defaults)
    }

    func testPointerTrackingStopsForIslandAndReduceMotion() {
        let appearance = ShelfAppearance.default
        XCTAssertTrue(appearance.shouldTrackPointer(isClassicShelf: true,
                                                    reduceMotion: false,
                                                    reduceTransparency: false))
        XCTAssertFalse(appearance.shouldTrackPointer(isClassicShelf: false,
                                                     reduceMotion: false,
                                                     reduceTransparency: false))
        XCTAssertFalse(appearance.shouldTrackPointer(isClassicShelf: true,
                                                     reduceMotion: true,
                                                     reduceTransparency: false))
    }

    func testPointerTrackingStopsWhenHighlightCannotMove() {
        for keyPath in [\ShelfAppearance.highlightStrength, \.elasticity, \.backgroundOpacity] {
            var appearance = ShelfAppearance.default
            appearance[keyPath: keyPath] = 0
            XCTAssertFalse(appearance.shouldTrackPointer(isClassicShelf: true,
                                                         reduceMotion: false,
                                                         reduceTransparency: false))
        }
        var appearance = ShelfAppearance.default
        appearance.followsPointer = false
        XCTAssertFalse(appearance.shouldTrackPointer(isClassicShelf: true,
                                                     reduceMotion: false,
                                                     reduceTransparency: false))
    }

    func testReduceTransparencyUsesVisibleBackgroundWithoutOverridingMotionChoice() {
        var appearance = ShelfAppearance.default
        appearance.backgroundOpacity = 0
        XCTAssertTrue(appearance.shouldTrackPointer(isClassicShelf: true,
                                                    reduceMotion: false,
                                                    reduceTransparency: true))
        appearance.followsPointer = false
        XCTAssertFalse(appearance.shouldTrackPointer(isClassicShelf: true,
                                                     reduceMotion: false,
                                                     reduceTransparency: true))
    }

    func testNestedEditsSurviveRelaunch() throws {
        try withStore { store, defaults in
            store.appearance.material = .clear
            store.appearance.theme = .dark
            store.appearance.tint = .mint
            store.appearance.backgroundOpacity = 0.35
            store.appearance.tintStrength = 0.32
            store.appearance.cornerRadius = 35
            store.appearance.highlightStrength = 0.75
            store.appearance.elasticity = 0.28
            store.appearance.followsPointer = false
            store.appearance.cardOpacity = 0.24
            store.appearance.cardCornerRadius = 18
            XCTAssertEqual(SettingsStore(defaults: defaults).appearance, store.appearance)
        }
    }

    func testResetKeepsExistingPlacementAndTriggers() throws {
        try withStore { store, defaults in
            store.shelfPosition = .left
            store.islandEnabled = false
            store.autoHide = true
            store.appearance.tint = .pink
            store.resetAppearance()
            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.appearance, .default)
            XCTAssertEqual(reloaded.shelfPosition, .left)
            XCTAssertFalse(reloaded.islandEnabled)
            XCTAssertTrue(reloaded.autoHide)
        }
    }

    func testInvalidGeometryAndNonFiniteValuesAreSafeAndPersisted() throws {
        try withStore { store, defaults in
            store.appearance.cornerRadius = -100
            store.appearance.cardCornerRadius = 1000
            store.appearance.cardOpacity = .infinity
            store.appearance.tintStrength = .nan
            store.appearance.backgroundOpacity = -20
            XCTAssertEqual(store.appearance.cornerRadius, 8)
            XCTAssertEqual(store.appearance.cardCornerRadius, 20)
            XCTAssertEqual(store.appearance.cardOpacity, ShelfAppearance.default.cardOpacity)
            XCTAssertEqual(store.appearance.tintStrength, ShelfAppearance.default.tintStrength)
            XCTAssertEqual(store.appearance.backgroundOpacity, 0)
            XCTAssertEqual(SettingsStore(defaults: defaults).appearance, store.appearance)
        }
    }

    func testDamagedAppearanceFallsBackWithoutResettingOtherPreferences() throws {
        try withStore { store, defaults in
            store.islandEnabled = false
            store.shelfWidth = 400
            defaults.set(Data("not JSON".utf8), forKey: "OpenYoink.appearance.v1")
            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.appearance, .default)
            XCTAssertFalse(reloaded.islandEnabled)
            XCTAssertEqual(reloaded.shelfWidth, 400)
        }
    }

    func testAddingOpacityPreservesLegacyAppearance() throws {
        try withStore { _, defaults in
            var legacy = ShelfAppearance.default
            legacy.theme = .dark
            legacy.tintStrength = 0
            legacy.highlightStrength = 0
            legacy.cornerRadius = 36
            legacy.cardOpacity = 1
            let encoded = try JSONEncoder().encode(legacy)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            json.removeValue(forKey: "backgroundOpacity")
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "OpenYoink.appearance.v1")
            let loaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(loaded.appearance, legacy)
            XCTAssertEqual(loaded.appearance.backgroundOpacity, 1)
        }
    }
}
