import AppKit
import Carbon
import XCTest
@testable import OpenYoink

/// HotKeyMonitor's pure logic: shortcut → Carbon modifier bits. (Carbon
/// registration and global event dispatch need a running WindowServer and
/// event loop, so they can't run headless; see HotKeyMonitor.)
final class HotKeyMonitorTests: XCTestCase {
    func testCarbonEventsReachOnlyTheirRegisteredShortcut() {
        let shelf = EventHotKeyID(signature: 0x4F59_484B, id: 1)
        let clipboard = EventHotKeyID(signature: 0x4F59_484B, id: 2)
        XCTAssertTrue(HotKeyMonitor.matches(shelf, registeredIdentifier: 1))
        XCTAssertFalse(HotKeyMonitor.matches(shelf, registeredIdentifier: 2))
        XCTAssertTrue(HotKeyMonitor.matches(clipboard, registeredIdentifier: 2))
        XCTAssertFalse(HotKeyMonitor.matches(clipboard, registeredIdentifier: 1))
        XCTAssertFalse(HotKeyMonitor.matches(EventHotKeyID(signature: 0x1234, id: 2), registeredIdentifier: 2))
    }

    private func shortcut(keyCode: UInt32 = 49,
                          command: Bool = false,
                          shift: Bool = false,
                          option: Bool = false,
                          control: Bool = false) -> SettingsStore.HotKeyShortcut {
        SettingsStore.HotKeyShortcut(keyCode: keyCode, command: command,
                                     shift: shift, option: option, control: control)
    }

    func testDefaultShortcut_mapsToCommandShift() {
        let modifiers = HotKeyMonitor.carbonModifiers(for: .default)
        XCTAssertEqual(modifiers, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testNoModifiers_mapsToZero() {
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut()), 0)
    }

    func testEachModifierMapsToItsOwnBit() {
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(command: true)), UInt32(cmdKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(shift: true)), UInt32(shiftKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(option: true)), UInt32(optionKey))
        XCTAssertEqual(HotKeyMonitor.carbonModifiers(for: shortcut(control: true)), UInt32(controlKey))
    }

    func testAllModifiersCombine() {
        let modifiers = HotKeyMonitor.carbonModifiers(
            for: shortcut(command: true, shift: true, option: true, control: true)
        )
        XCTAssertEqual(modifiers,
                       UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey))
    }

    func testMatchesIgnoresIncidentalKeyboardFlagsButRequiresExactShortcutModifiers() throws {
        let expected = shortcut(keyCode: 8, command: true, option: true)
        let matching = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .capsLock, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        let missingOption = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertTrue(HotKeyMonitor.matches(matching, shortcut: expected))
        XCTAssertFalse(HotKeyMonitor.matches(missingOption, shortcut: expected))
    }

    // MARK: - DoublePressDiscriminator

    func testDoublePress_secondPressInsideWindow_isDouble() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 10.0), .firstPressPending)
        XCTAssertTrue(discriminator.hasPending)
        XCTAssertEqual(discriminator.press(at: 10.25), .doublePress)
        XCTAssertFalse(discriminator.hasPending)
    }

    func testDoublePress_secondPressOutsideWindow_startsNewPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 10.0), .firstPressPending)
        // A second press outside the window isn't a double click but a new pending click.
        XCTAssertEqual(discriminator.press(at: 10.5), .firstPressPending)
        XCTAssertTrue(discriminator.hasPending)
    }

    func testDoublePress_exactWindowBoundary_countsAsDouble() {
        // Boundaries use exactly representable binary fractions (0.5/1.5), so float
        // error like 0.3's can't hide "exactly at the window" (the check is <= window).
        var discriminator = DoublePressDiscriminator(window: 0.5)
        XCTAssertEqual(discriminator.press(at: 1.0), .firstPressPending)
        XCTAssertEqual(discriminator.press(at: 1.5), .doublePress)
    }

    func testDoublePress_confirmedSingle_rearmsForNextPress() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 1.0), .firstPressPending)
        discriminator.confirmPending() // the delay fired: a single click
        XCTAssertFalse(discriminator.hasPending)
        // The next press is a new first press, unrelated to the last click.
        XCTAssertEqual(discriminator.press(at: 1.2), .firstPressPending)
    }

    func testDoublePress_triplePressIsDoublePlusPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 0.0), .firstPressPending)
        XCTAssertEqual(discriminator.press(at: 0.2), .doublePress)
        // The third press of a triple: pending again (a fourth may follow).
        XCTAssertEqual(discriminator.press(at: 0.4), .firstPressPending)
    }

    func testDoublePress_resetDiscardsPending() {
        var discriminator = DoublePressDiscriminator(window: 0.3)
        XCTAssertEqual(discriminator.press(at: 0.0), .firstPressPending)
        discriminator.reset()
        XCTAssertFalse(discriminator.hasPending)
        XCTAssertEqual(discriminator.press(at: 0.1), .firstPressPending)
    }
}
