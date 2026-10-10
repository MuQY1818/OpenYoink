import IOKit.ps
import XCTest
@testable import OpenYoink

@MainActor
final class PowerSourceMonitorTests: XCTestCase {
    func testStartingWhileLockedResumesSamplingOnUnlockAndStaysStoppedAfterStop() async {
        var allowed = false
        var reads = 0
        let monitor = PowerSourceMonitor(samplingAllowed: { allowed }, snapshotProvider: {
            reads += 1
            return .init(hasBattery: true, percentage: 80, isCharging: false, isConnectedToPower: false)
        })
        monitor.start()
        monitor.start()
        XCTAssertEqual(reads, 0)
        allowed = true
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        for _ in 0..<20 where reads == 0 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(monitor.snapshot.hasBattery)
        monitor.stop()
        monitor.refresh()
        NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(monitor.isRunning)
    }

    func testSnapshotParsesCapacityAndPowerState() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 45,
            kIOPSMaxCapacityKey: 90,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsChargingKey: true,
            kIOPSVoltageKey: 12_000,
            kIOPSCurrentKey: 2_000,
        ])
        XCTAssertEqual(snapshot.percentage, 50)
        XCTAssertTrue(snapshot.hasBattery)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.isConnectedToPower)
        XCTAssertEqual(snapshot.powerWatts, 24)
    }

    func testBatteryPowerUsesRegistryFallbackAndDischargeDirection() {
        let snapshot = PowerSourceMonitor.snapshot(from: [
            kIOPSCurrentCapacityKey: 75,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: false,
            kIOPSVoltageKey: 0,
            kIOPSCurrentKey: 0,
        ], registryProperties: [
            "Voltage": 12_500,
            "InstantAmperage": 800,
        ])

        XCTAssertEqual(snapshot.powerWatts, -10)
    }

    func testMissingMaximumIsUnavailable() {
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: [:]), .unavailable)
        XCTAssertEqual(PowerSourceMonitor.snapshot(from: nil), .unavailable)
    }

    func testThresholdNotificationIsDeduplicatedWithinBand() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 21))
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 18))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 1)
        monitor.process(snapshot(percentage: 10))
        XCTAssertEqual(activities.compactMap { $0 }.filter { $0.id == "battery.low" }.count, 2)
    }

    func testPowerChangeExpiresAfterTwoPointFiveSeconds() {
        let now = Date(timeIntervalSince1970: 5_000)
        let monitor = PowerSourceMonitor(now: { now })
        var latest: IslandActivity?
        monitor.onActivity = { latest = $0 }
        monitor.process(snapshot(percentage: 80, power: false))
        monitor.process(snapshot(percentage: 80, power: true))
        XCTAssertEqual(latest?.id, "battery.power-change")
        XCTAssertEqual(latest?.expiresAt, now.addingTimeInterval(2.5))
    }

    func testRecoveringAboveLowBatteryThresholdClearsActivity() {
        let monitor = PowerSourceMonitor()
        var activities: [IslandActivity?] = []
        monitor.onActivity = { activities.append($0) }
        monitor.process(snapshot(percentage: 20))
        monitor.process(snapshot(percentage: 21))
        XCTAssertEqual(activities.first.flatMap { $0 }?.id, "battery.low")
        XCTAssertNil(activities.last ?? nil)
    }

    private func snapshot(percentage: Int, power: Bool = false) -> PowerSourceMonitor.Snapshot {
        .init(hasBattery: true, percentage: percentage,
              isCharging: power, isConnectedToPower: power)
    }
}
