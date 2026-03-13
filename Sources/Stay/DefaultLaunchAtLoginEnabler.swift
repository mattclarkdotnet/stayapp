import Foundation

enum DefaultLaunchAtLoginResult: Equatable {
    case enabledByDefault
    case alreadyConfigured
    case unavailable
}

protocol LaunchAtLoginPreferenceStoring {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Bool, forKey defaultName: String)
}

extension UserDefaults: LaunchAtLoginPreferenceStoring {}

// Design goal: make "launch at login by default" a one-time policy decision
// instead of imperative UI logic, so user opt-out stays stable after first launch.
struct DefaultLaunchAtLoginEnabler {
    static let hasConfiguredDefaultKey = "hasConfiguredDefaultLaunchAtLogin"

    private let controller: any LaunchAtLoginControlling
    private let preferences: any LaunchAtLoginPreferenceStoring
    private let configuredKey: String

    init(
        controller: any LaunchAtLoginControlling,
        preferences: any LaunchAtLoginPreferenceStoring = UserDefaults.standard,
        configuredKey: String = DefaultLaunchAtLoginEnabler.hasConfiguredDefaultKey
    ) {
        self.controller = controller
        self.preferences = preferences
        self.configuredKey = configuredKey
    }

    func configureIfNeeded() throws -> DefaultLaunchAtLoginResult {
        guard controller.status() != .unavailable else {
            return .unavailable
        }

        if preferences.bool(forKey: configuredKey) {
            return .alreadyConfigured
        }

        switch controller.status() {
        case .enabled, .requiresApproval:
            preferences.set(true, forKey: configuredKey)
            return .alreadyConfigured
        case .disabled:
            try controller.setEnabled(true)
            preferences.set(true, forKey: configuredKey)
            return .enabledByDefault
        case .unavailable:
            return .unavailable
        }
    }
}
