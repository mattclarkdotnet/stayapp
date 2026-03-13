import Foundation
import ServiceManagement
import Testing

@testable import Stay

@Suite("LaunchAtLoginController")
struct LaunchAtLoginControllerTests {
    @Test("Installed app maps enabled login-item service to enabled status")
    func installedBundleEnabledStatus() {
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/Stay.app", isDirectory: true),
            bundleIdentifier: "net.mattclark.stay",
            service: StubLoginItemService(status: .enabled)
        )

        #expect(controller.status() == .enabled)
    }

    @Test("Non-app bundle reports login-item control as unavailable")
    func nonAppBundleIsUnavailable() {
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/tmp/Stay", isDirectory: false),
            bundleIdentifier: nil,
            service: StubLoginItemService(status: .enabled)
        )

        #expect(controller.status() == .unavailable)
    }

    @Test("Requires-approval service status is surfaced explicitly")
    func requiresApprovalStatus() {
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/Stay.app", isDirectory: true),
            bundleIdentifier: "net.mattclark.stay",
            service: StubLoginItemService(status: .requiresApproval)
        )

        #expect(controller.status() == .requiresApproval)
    }

    @Test("Not-found service status is treated as disabled for main app registration")
    func notFoundStatusBehavesLikeDisabled() {
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/Stay.app", isDirectory: true),
            bundleIdentifier: "net.mattclark.stay",
            service: StubLoginItemService(status: .notFound)
        )

        #expect(controller.status() == .disabled)
    }

    @Test("User-controlled enable calls register on the service")
    func enableCallsRegister() throws {
        let service = StubLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/Stay.app", isDirectory: true),
            bundleIdentifier: "net.mattclark.stay",
            service: service
        )

        try controller.setEnabled(true)

        #expect(service.registerCallCount == 1)
        #expect(service.unregisterCallCount == 0)
    }

    @Test("User-controlled disable calls unregister on the service")
    func disableCallsUnregister() throws {
        let service = StubLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/Stay.app", isDirectory: true),
            bundleIdentifier: "net.mattclark.stay",
            service: service
        )

        try controller.setEnabled(false)

        #expect(service.unregisterCallCount == 1)
        #expect(service.registerCallCount == 0)
    }
}

private final class StubLoginItemService: LoginItemServiceProviding {
    let status: SMAppService.Status
    var registerCallCount = 0
    var unregisterCallCount = 0
    var openSettingsCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
    }

    func unregister() throws {
        unregisterCallCount += 1
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}
