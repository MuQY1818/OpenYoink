import Foundation
import ServiceManagement

/// The minimal ServiceManagement surface, so tests don't touch real login items.
@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginController.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
@Observable
final class LaunchAtLoginController {
    enum Status: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case unavailable
    }

    private(set) var status: Status = .notRegistered
    private(set) var errorMessage: String?

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool { status == .requiresApproval }
    var isAvailable: Bool { status != .unavailable }

    private let service: any LaunchAtLoginServicing

    convenience init() {
        self.init(service: SystemLaunchAtLoginService())
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        refresh()
    }

    func refresh() {
        let refreshedStatus = service.status
        if refreshedStatus != status {
            // The user may have approved or revoked in System Settings; once the state
            // really changed, the previous registration error is stale.
            errorMessage = nil
        }
        status = refreshedStatus
    }

    func setRequested(_ requested: Bool) {
        errorMessage = nil
        guard isAvailable else { return }
        do {
            if requested {
                guard !isRequested else { return }
                try service.register()
            } else {
                guard isRequested else { return }
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginController.Status {
        Self.map(service.status)
    }

    /// The first `mainApp` query may return `.notFound` because Background Task
    /// Management has no record yet; the first `register()` creates it. Treat it
    /// as "not registered" so the toggle isn't disabled before the user could
    /// ever register.
    static func map(_ status: SMAppService.Status) -> LaunchAtLoginController.Status {
        switch status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notRegistered
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
