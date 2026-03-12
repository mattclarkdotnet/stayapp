import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginError: Error, Equatable {
    case unavailable
    case underlying(domain: String, code: Int)

    init(_ error: NSError) {
        self = .underlying(domain: error.domain, code: error.code)
    }
}

protocol LaunchAtLoginControlling {
    func status() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

protocol LoginItemServiceProviding {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct MainAppLoginItemService: LoginItemServiceProviding {
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// Design goal: keep login-item behavior user-controlled, but only expose the
// control when Stay is running from a real app bundle with a stable identity.
struct LaunchAtLoginController: LaunchAtLoginControlling {
    private let bundleURL: URL
    private let bundleIdentifier: String?
    private let service: any LoginItemServiceProviding

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        service: any LoginItemServiceProviding = MainAppLoginItemService()
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.service = service
    }

    func status() -> LaunchAtLoginStatus {
        guard isBundleInstallEligible else {
            return .unavailable
        }

        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered, .notFound:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isBundleInstallEligible else {
            throw LaunchAtLoginError.unavailable
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            throw LaunchAtLoginError(error as NSError)
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private var isBundleInstallEligible: Bool {
        bundleURL.pathExtension == "app" && bundleIdentifier?.isEmpty == false
    }
}
