import AppKit
import Carbon
import OSLog

/// Tells a single hot-key press from a double press. A first press is
/// pending; a second one within `window` makes a double press (and cancels
/// the single); a later one starts over. The caller confirms a single press
/// with `confirmPending()` once the window has passed.
struct DoublePressDiscriminator: Sendable, Equatable {
    enum PressResult: Sendable, Equatable {
        /// Wait `window` for a second press.
        case firstPressPending
        case doublePress
    }

    /// About the system's double-click interval.
    let window: TimeInterval
    /// A single press is waiting to be confirmed.
    private(set) var hasPending = false
    private var lastPressTime: TimeInterval?

    init(window: TimeInterval) {
        self.window = window
    }

    /// `time` is monotonic, e.g. `ProcessInfo.systemUptime`.
    mutating func press(at time: TimeInterval) -> PressResult {
        if hasPending, let lastPressTime, time - lastPressTime <= window {
            hasPending = false
            self.lastPressTime = nil
            return .doublePress
        }
        hasPending = true
        lastPressTime = time
        return .firstPressPending
    }

    mutating func confirmPending() {
        hasPending = false
        lastPressTime = nil
    }

    /// Drops a pending press (on disable or re-registration).
    mutating func reset() {
        hasPending = false
        lastPressTime = nil
    }
}

/// Global hot key monitor: toggles the shelf from any app.

///
/// Hot-key backends:
/// - **Carbon `RegisterEventHotKey` — primary.** Needs no Accessibility
///   permission, the registration result is programmatically detectable
///   (`eventHotKeyExistsErr` on conflict), and the hot key is consumed by the
///   system so the foreground app never sees it.
/// - **`NSEvent` global monitor — best-effort fallback.** Registration always
///   "succeeds"; whether events actually arrive cannot be probed, and the
///   event cannot be consumed, so ⌘⇧Space would also reach the foreground
///   app. Used only when Carbon registration fails.
///
/// Registration state (`isActive` / `activeBackend` / `registrationError`) is
/// observable so Settings can surface conflicts.
@MainActor
@Observable
final class HotKeyMonitor {
    /// Event backend currently delivering the hot key.
    enum Backend: String, Sendable {
        case carbon, nsEvent
    }

    /// Whether a backend is actively listening.
    private(set) var isActive = false
    /// Backend in use while `isActive` is true.
    private(set) var activeBackend: Backend?
    /// Human-readable registration failure (e.g. shortcut conflict), for the
    /// settings page. Nil when Carbon registration succeeded or the monitor
    /// is disabled.
    private(set) var registrationError: String?

    private var shortcut: SettingsStore.HotKeyShortcut?

    private var actionBox: HotKeyActionBox?
    private var enabled = false
    private let hotKeyIdentifier: UInt32

    private let onPress: @MainActor @Sendable () -> Void
    private let onDoublePress: @MainActor @Sendable () -> Void

    private var doublePressEnabled = false
    private var discriminator: DoublePressDiscriminator
    /// Bumped on every press or reset, so a delayed single press can tell it
    /// was superseded (no single press after a double press).
    private var pressGeneration: UInt64 = 0

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handlerUserData: UnsafeMutableRawPointer?
    private var nsEventMonitor: EventMonitor<Bool>?

    private let logger = Log.make(category: "HotKey")

    /// Four-character signature for our hot key IDs ('OYHK').
    private nonisolated static let hotKeySignature = OSType(0x4F59_484B)

    init(shortcut: SettingsStore.HotKeyShortcut? = .default,
         hotKeyIdentifier: UInt32 = 1,
         doublePressWindow: TimeInterval = 0.3,
         onPress: @escaping @MainActor @Sendable () -> Void,
         onDoublePress: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.hotKeyIdentifier = hotKeyIdentifier
        self.onPress = onPress
        self.onDoublePress = onDoublePress
        self.discriminator = DoublePressDiscriminator(window: doublePressWindow)
    }

    // MARK: - Lifecycle

    /// Enables/disables the monitor. No-op when the state doesn't change.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            register()
        } else {
            unregister()
            registrationError = nil
        }
    }

    /// Hot-updates the shortcut; re-registers immediately when enabled.
    /// A nil shortcut (cleared in the shortcut recorder) unregisters and stays
    /// inactive until a new shortcut is recorded.
    func updateShortcut(_ shortcut: SettingsStore.HotKeyShortcut?) {
        guard shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        if enabled {
            register()
        }
    }

    func setDoublePressEnabled(_ enabled: Bool) {
        guard enabled != doublePressEnabled else { return }
        doublePressEnabled = enabled
        // Drop a delayed press from the old mode; otherwise it would fire
        // after the next, now immediate, press and toggle the shelf twice.
        pressGeneration &+= 1
        discriminator.reset()
    }

    /// Every press arrives here, from either backend. With double press on,
    /// a single press fires one window late.
    private func handlePress() {
        guard doublePressEnabled else {
            onPress()
            return
        }
        switch discriminator.press(at: ProcessInfo.processInfo.systemUptime) {
        case .doublePress:
            pressGeneration &+= 1
            onDoublePress()
        case .firstPressPending:
            pressGeneration &+= 1
            let generation = pressGeneration
            let window = discriminator.window
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(window * 1000)))
                guard let self, !Task.isCancelled else { return }

                guard self.discriminator.hasPending, self.pressGeneration == generation else { return }
                self.discriminator.confirmPending()
                self.onPress()
            }
        }
    }

    // MARK: - Registration

    private func requireActionBox() -> HotKeyActionBox {
        if let actionBox { return actionBox }
        let box = HotKeyActionBox(identifier: hotKeyIdentifier) { [weak self] in
            self?.handlePress()
        }
        actionBox = box
        return box
    }

    private func register() {
        unregister()
        guard let shortcut else {
            // Cleared shortcut: no registration, but no error either — the
            // settings page shows "Not Set" instead of a conflict banner.
            registrationError = nil
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: hotKeyIdentifier)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         Self.carbonModifiers(for: shortcut),
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            logger.warning("RegisterEventHotKey failed with OSStatus \(status); falling back to NSEvent global monitor")
            registrationError = String(localized: "Hot key registration failed (OSStatus \(status)); another app may already hold this shortcut.")
            installNSEventFallback()
            return
        }
        hotKeyRef = ref
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(requireActionBox()).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(),
                                         Self.carbonEventHandler,
                                         1,
                                         &eventType,
                                         userData,
                                         &ref)
        guard status == noErr, let ref else {
            Unmanaged<HotKeyActionBox>.fromOpaque(userData).release()
            logger.error("InstallEventHandler failed with OSStatus \(status)")
            registrationError = String(localized: "Hot key event handler installation failed (OSStatus \(status)).")
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                self.hotKeyRef = nil
            }
            installNSEventFallback()
            return
        }
        handlerRef = ref
        handlerUserData = userData
        isActive = true
        activeBackend = .carbon
        registrationError = nil
    }

    /// Best-effort fallback when Carbon registration fails. Note: an NSEvent
    /// global monitor cannot be probed for actual delivery and cannot consume
    /// the event — the foreground app still receives the key combination.
    private func installNSEventFallback() {
        guard let shortcut else { return }
        let actionBox = requireActionBox()
        let monitor = EventMonitor(matching: .keyDown, includesLocal: false,
                                   capture: { HotKeyMonitor.matches($0, shortcut: shortcut) }) { matches in
            if matches { actionBox.action() }
        }
        nsEventMonitor = monitor
        monitor.start()
        if monitor.isRunning {
            isActive = true
            activeBackend = .nsEvent
        }
    }

    private func unregister() {
        pressGeneration &+= 1
        discriminator.reset()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let handlerUserData {
            Unmanaged<HotKeyActionBox>.fromOpaque(handlerUserData).release()
            self.handlerUserData = nil
        }
        nsEventMonitor?.stop()
        nsEventMonitor = nil
        isActive = false
        activeBackend = nil
    }

    // MARK: - Matching & modifier mapping (pure, unit-testable)

    /// Carbon event callback. Multiple monitors share the dispatcher, so
    /// each handler must check the signature and registration ID. The callback is a plain C
    /// function without actor isolation; the action hops to the MainActor
    /// explicitly instead of assuming a thread.
    private nonisolated static let carbonEventHandler: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let box = Unmanaged<HotKeyActionBox>.fromOpaque(userData).takeUnretainedValue()
        var identifier = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
              matches(identifier, registeredIdentifier: box.identifier) else {
            return OSStatus(eventNotHandledErr)
        }
        Task { @MainActor in
            box.action()
        }
        return noErr
    }

    nonisolated static func matches(_ eventID: EventHotKeyID, registeredIdentifier: UInt32) -> Bool {
        eventID.signature == hotKeySignature && eventID.id == registeredIdentifier
    }

    /// Maps the persisted shortcut to Carbon modifier bits (`cmdKey` etc.).
    nonisolated static func carbonModifiers(for shortcut: SettingsStore.HotKeyShortcut) -> UInt32 {
        var modifiers: UInt32 = 0
        if shortcut.command { modifiers |= UInt32(cmdKey) }
        if shortcut.shift { modifiers |= UInt32(shiftKey) }
        if shortcut.option { modifiers |= UInt32(optionKey) }
        if shortcut.control { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// Exact match on key code + device-independent modifiers (NSEvent
    /// fallback path only; the Carbon path matches by registration).
    nonisolated static func matches(_ event: NSEvent,
                                    shortcut: SettingsStore.HotKeyShortcut) -> Bool {
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        flags.subtract([.capsLock, .function, .numericPad])
        var expected: NSEvent.ModifierFlags = []
        if shortcut.command { expected.insert(.command) }
        if shortcut.shift { expected.insert(.shift) }
        if shortcut.option { expected.insert(.option) }
        if shortcut.control { expected.insert(.control) }
        return flags == expected && UInt32(event.keyCode) == shortcut.keyCode
    }
}

/// `Sendable` box around the press route so the Carbon C callback (no actor
/// isolation) can reach the MainActor without strongly capturing the monitor
/// Immutable after creation; reference lifetime is managed explicitly via
/// `Unmanaged` across install/remove of the event handler.
private final class HotKeyActionBox: @unchecked Sendable {
    let action: @MainActor @Sendable () -> Void
    let identifier: UInt32

    init(identifier: UInt32, _ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        self.identifier = identifier
    }
}
