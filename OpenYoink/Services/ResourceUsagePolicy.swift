import AppKit

enum ResourceUsagePolicy {
    static func samplingAllowed(isSleeping: Bool, isLocked: Bool) -> Bool { !isSleeping && !isLocked }
    static func batteryInterval(isExpanded: Bool, isConstrained: Bool) -> Duration {
        isConstrained ? .seconds(30) : isExpanded ? .seconds(2) : .seconds(15)
    }
    static func mediaInterval(isExpanded: Bool, isConstrained: Bool, hasPlayer: Bool) -> Duration {
        isConstrained ? .seconds(15) : !hasPlayer ? .seconds(15) : isExpanded ? .seconds(2) : .seconds(5)
    }
}

extension Notification.Name {
    static let openYoinkResourcePolicyDidChange = Notification.Name("OpenYoink.resourcePolicyDidChange")
}

/// Notification-driven state shared by samplers. No polling and no lock-screen UI access.
@MainActor
final class ResourceUsageState {
    static let shared = ResourceUsageState()
    private(set) var isSleeping = false
    private(set) var isLocked = false
    var samplingAllowed: Bool { ResourceUsagePolicy.samplingAllowed(isSleeping: isSleeping, isLocked: isLocked) }
    var isConstrained: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
            || [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
    }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { $0.isSleeping = true }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.isSleeping = false }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false }
        observe(.default, .NSProcessInfoPowerStateDidChange) { _ in }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { _ in }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (ResourceUsageState) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
                NotificationCenter.default.post(name: .openYoinkResourcePolicyDidChange, object: nil)
            }
        }
        tokens.append((center, token))
    }
}
