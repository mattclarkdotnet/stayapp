import Foundation
import Testing

@testable import Stay

@Suite("DefaultLaunchAtLoginEnabler")
struct DefaultLaunchAtLoginEnablerTests {
    @Test("First installed launch enables launch at login by default")
    func firstLaunchEnablesByDefault() throws {
        let controller = StubLaunchAtLoginController(statusValue: .disabled)
        let preferences = InMemoryLaunchAtLoginPreferences()
        let enabler = DefaultLaunchAtLoginEnabler(
            controller: controller,
            preferences: preferences
        )

        let result = try enabler.configureIfNeeded()

        #expect(result == .enabledByDefault)
        #expect(controller.setEnabledCalls == [true])
        #expect(preferences.bool(forKey: DefaultLaunchAtLoginEnabler.hasConfiguredDefaultKey))
    }

    @Test("Already enabled launch at login records configuration without changing user state")
    func enabledStateIsRecordedWithoutMutation() throws {
        let controller = StubLaunchAtLoginController(statusValue: .enabled)
        let preferences = InMemoryLaunchAtLoginPreferences()
        let enabler = DefaultLaunchAtLoginEnabler(
            controller: controller,
            preferences: preferences
        )

        let result = try enabler.configureIfNeeded()

        #expect(result == .alreadyConfigured)
        #expect(controller.setEnabledCalls.isEmpty)
        #expect(preferences.bool(forKey: DefaultLaunchAtLoginEnabler.hasConfiguredDefaultKey))
    }

    @Test("Unavailable login-item control does not record configuration")
    func unavailableStateDoesNothing() throws {
        let controller = StubLaunchAtLoginController(statusValue: .unavailable)
        let preferences = InMemoryLaunchAtLoginPreferences()
        let enabler = DefaultLaunchAtLoginEnabler(
            controller: controller,
            preferences: preferences
        )

        let result = try enabler.configureIfNeeded()

        #expect(result == .unavailable)
        #expect(controller.setEnabledCalls.isEmpty)
        #expect(!preferences.bool(forKey: DefaultLaunchAtLoginEnabler.hasConfiguredDefaultKey))
    }

    @Test("Once configured, later disabled state is preserved as user opt-out")
    func configuredPreferencePreventsReEnable() throws {
        let controller = StubLaunchAtLoginController(statusValue: .disabled)
        let preferences = InMemoryLaunchAtLoginPreferences()
        preferences.set(true, forKey: DefaultLaunchAtLoginEnabler.hasConfiguredDefaultKey)
        let enabler = DefaultLaunchAtLoginEnabler(
            controller: controller,
            preferences: preferences
        )

        let result = try enabler.configureIfNeeded()

        #expect(result == .alreadyConfigured)
        #expect(controller.setEnabledCalls.isEmpty)
    }
}

private final class StubLaunchAtLoginController: LaunchAtLoginControlling {
    let statusValue: LaunchAtLoginStatus
    var setEnabledCalls: [Bool] = []

    init(statusValue: LaunchAtLoginStatus) {
        self.statusValue = statusValue
    }

    func status() -> LaunchAtLoginStatus {
        statusValue
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
    }

    func openSystemSettings() {}
}

private final class InMemoryLaunchAtLoginPreferences: LaunchAtLoginPreferenceStoring {
    private var values: [String: Bool] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] ?? false
    }

    func set(_ value: Bool, forKey defaultName: String) {
        values[defaultName] = value
    }
}
