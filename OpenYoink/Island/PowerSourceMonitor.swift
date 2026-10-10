import Foundation
import IOKit
import IOKit.ps
import Observation

struct BatteryElectricalSample: Equatable, Sendable {
    let voltageMillivolts: Int64
    let currentMilliamps: Int64

    func signedPowerWatts(isCharging: Bool, isConnectedToPower: Bool) -> Double {
        let rawWatts = Double(voltageMillivolts) * Double(currentMilliamps) / 1_000_000
        if isCharging { return abs(rawWatts) }
        if !isConnectedToPower { return -abs(rawWatts) }
        return rawWatts
    }
}

struct BatteryPowerSample: Equatable, Sendable {
    let timestamp: Date
    let watts: Double
}

enum BatteryElectricalReader {
    private static let registryCurrentKeys = ["InstantAmperage", "Amperage"]

    static func sample(
        powerSourceDescription: [String: Any],
        registryProperties: [String: Any]? = nil
    ) -> BatteryElectricalSample? {
        let sourceVoltage = integer(powerSourceDescription[kIOPSVoltageKey])
        let sourceCurrent = integer(powerSourceDescription[kIOPSCurrentKey])
        let registryVoltage = integer(registryProperties?["Voltage"])
        // Apple silicon can report a zero IOPS current while the battery
        // registry still publishes a live instantaneous value.
        let registryCurrents = registryCurrentKeys.compactMap {
            integer(registryProperties?[$0])
        }
        let registryCurrent = registryCurrents.first(where: { $0 != 0 })
            ?? registryCurrents.first

        guard let voltage = validVoltage(sourceVoltage) ?? validVoltage(registryVoltage) else {
            return nil
        }
        let current: Int64?
        if let sourceCurrent, sourceCurrent != 0 {
            current = sourceCurrent
        } else {
            current = registryCurrent ?? sourceCurrent
        }
        guard let current, validCurrent(current) else { return nil }
        return .init(voltageMillivolts: voltage, currentMilliamps: current)
    }

    static func readRegistryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func validVoltage(_ value: Int64?) -> Int64? {
        guard let value, value > 0, value <= 100_000 else { return nil }
        return value
    }

    private static func validCurrent(_ value: Int64) -> Bool {
        value != Int64.min && abs(value) <= 100_000
    }
}

enum BatteryPowerFormatting {
    static func string(watts: Double) -> String {
        let normalized = abs(watts) < 0.05 ? 0 : watts
        let format = normalized == 0 ? "%.1f W" : "%+.1f W"
        return String(format: format, locale: .current, normalized)
    }
}

@MainActor
@Observable
final class PowerSourceMonitor: IslandModule {
    static let powerHistoryDuration: TimeInterval = 2 * 60
    static let maximumPowerHistoryCount = 60

    struct Snapshot: Equatable, Sendable {
        var hasBattery: Bool
        var percentage: Int
        var isCharging: Bool
        var isConnectedToPower: Bool
        var powerWatts: Double? = nil

        static let unavailable = Snapshot(hasBattery: false,
                                          percentage: 0,
                                          isCharging: false,
                                          isConnectedToPower: false,
                                          powerWatts: nil)
    }

    let descriptor = IslandModuleDescriptor(
        id: .battery,
        title: String(localized: "Battery"),
        systemImage: "battery.75percent",
        order: 3,
        isCore: false
    )

    @ObservationIgnored
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    private var lastAlertBand: Int?
    private let nowProvider: @MainActor () -> Date
    private let fullChargeAlertEnabled: @MainActor () -> Bool
    private(set) var snapshot: Snapshot = .unavailable
    private(set) var powerHistory: [BatteryPowerSample] = []
    private(set) var isRunning = false
    @ObservationIgnored private let isSelectedAndExpanded: @MainActor () -> Bool
    @ObservationIgnored private let samplingAllowed: @MainActor () -> Bool
    @ObservationIgnored private let snapshotProvider: @MainActor () -> Snapshot
    @ObservationIgnored nonisolated(unsafe) private var resourceToken: NSObjectProtocol?
    var onActivity: (@MainActor (IslandActivity?) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    init(now: @escaping @MainActor () -> Date = Date.init,
         isSelectedAndExpanded: @escaping @MainActor () -> Bool = { false },
         samplingAllowed: @escaping @MainActor () -> Bool = { ResourceUsageState.shared.samplingAllowed },
         snapshotProvider: @escaping @MainActor () -> Snapshot = { PowerSourceMonitor.readSnapshot() },
         fullChargeAlertEnabled: @escaping @MainActor () -> Bool = { false }) {
        self.nowProvider = now
        self.isSelectedAndExpanded = isSelectedAndExpanded
        self.samplingAllowed = samplingAllowed
        self.snapshotProvider = snapshotProvider
        self.fullChargeAlertEnabled = fullChargeAlertEnabled
    }

    deinit {
        pollingTask?.cancel()
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = ResourceUsageState.shared
        resourceToken = NotificationCenter.default.addObserver(forName: .openYoinkResourcePolicyDidChange,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }
        restartPolling()
    }

    private func registerPowerNotificationsIfNeeded() {
        // Desktops and external-only displays have no battery transitions to
        // observe. Keep the unavailable snapshot visible without retaining an
        // otherwise idle run-loop source.
        guard snapshot.hasBattery, runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
            }
        }, context) else { return }
        let source = unmanaged.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func restartPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        guard isRunning, samplingAllowed() else { return }
        refresh()
        guard snapshot.hasBattery else { return }
        registerPowerNotificationsIfNeeded()
        pollingTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                let interval = ResourceUsagePolicy.batteryInterval(isExpanded: self.isSelectedAndExpanded(),
                                                                   isConstrained: ResourceUsageState.shared.isConstrained)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self.refresh()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        if let resourceToken { NotificationCenter.default.removeObserver(resourceToken) }
        resourceToken = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
            self.runLoopSource = nil
        }
        onActivity?(nil)
    }

    func refresh() {
        guard isRunning, samplingAllowed() else { return }
        process(snapshotProvider())
    }

    /// Internal deterministic seam for pure unit tests and future power-event
    /// adapters. Production still enters only through the IOKit notification.
    func process(_ current: Snapshot) {
        let previous = snapshot
        snapshot = current
        recordPowerSample(from: current)
        evaluateActivity(previous: previous, current: current)
        onStateChange?()
    }

    private func recordPowerSample(from snapshot: Snapshot) {
        guard let watts = snapshot.powerWatts, watts.isFinite else { return }
        let timestamp = nowProvider()
        let sample = BatteryPowerSample(timestamp: timestamp, watts: watts)

        // Power-source notifications can arrive next to the regular poll. Fold
        // near-simultaneous readings together so the chart keeps a steady pace.
        if let last = powerHistory.last,
           timestamp.timeIntervalSince(last.timestamp) < 0.5 {
            powerHistory[powerHistory.count - 1] = sample
        } else {
            powerHistory.append(sample)
        }

        let cutoff = timestamp.addingTimeInterval(-Self.powerHistoryDuration)
        powerHistory.removeAll { $0.timestamp < cutoff }
        if powerHistory.count > Self.maximumPowerHistoryCount {
            powerHistory.removeFirst(
                powerHistory.count - Self.maximumPowerHistoryCount
            )
        }
    }

    static func snapshot(
        from description: [String: Any]?,
        registryProperties: [String: Any]? = nil
    ) -> Snapshot {
        guard let description else { return .unavailable }
        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 0
        guard maximum > 0 else { return .unavailable }
        let percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
        let state = description[kIOPSPowerSourceStateKey] as? String
        let onAC = state == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let powerWatts = BatteryElectricalReader.sample(
            powerSourceDescription: description,
            registryProperties: registryProperties
        )?.signedPowerWatts(isCharging: charging, isConnectedToPower: onAC)
        return Snapshot(hasBattery: true,
                        percentage: percentage,
                        isCharging: charging,
                        isConnectedToPower: onAC,
                        powerWatts: powerWatts)
    }

    private static func readSnapshot() -> Snapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .unavailable }

        let registryProperties = BatteryElectricalReader.readRegistryProperties()
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            return snapshot(from: description, registryProperties: registryProperties)
        }
        return .unavailable
    }

    private func evaluateActivity(previous: Snapshot, current: Snapshot) {
        guard current.hasBattery else {
            lastAlertBand = nil
            onActivity?(nil)
            return
        }

        let alertBand: Int? = if current.percentage <= 10 {
            10
        } else if current.percentage <= 20 {
            20
        } else {
            nil
        }
        if alertBand != lastAlertBand, let alertBand {
            lastAlertBand = alertBand
            onActivity?(.init(
                id: "battery.low",
                moduleID: .battery,
                priority: .criticalBattery,
                title: alertBand == 10
                    ? String(localized: "Battery critically low")
                    : String(localized: "Battery low"),
                detail: "\(current.percentage)%",
                systemImage: "battery.25percent",
                expiresAt: nil
            ))
            return
        } else if alertBand == nil, lastAlertBand != nil {
            lastAlertBand = nil
            onActivity?(nil)
        }

        guard previous.hasBattery else { return }
        if previous.isConnectedToPower != current.isConnectedToPower {
            onActivity?(.init(
                id: "battery.power-change",
                moduleID: .battery,
                priority: .powerChange,
                title: current.isConnectedToPower
                    ? String(localized: "Power connected")
                    : String(localized: "Running on battery"),
                detail: "\(current.percentage)%",
                systemImage: current.isConnectedToPower ? "bolt.fill" : "battery.75percent",
                expiresAt: nowProvider().addingTimeInterval(2.5)
            ))
        } else if fullChargeAlertEnabled(),
                  previous.percentage < 100,
                  current.percentage == 100 {
            onActivity?(.init(id: "battery.full", moduleID: .battery,
                              priority: .powerChange,
                              title: String(localized: "Battery fully charged"),
                              detail: nil, systemImage: "battery.100percent",
                              expiresAt: nowProvider().addingTimeInterval(2.5)))
        }
    }
}
