import AppKit
import Foundation
import OSLog
import StayCore

// Design goal: translate macOS sleep/wake notifications into coordinator events
// without adding state or business logic in the observer layer.
@MainActor
final class SleepWakeObserver: NSObject {
    private let logger = Logger(subsystem: "com.stay.app", category: "SleepWakeObserver")
    private let center: NotificationCenter
    private let coordinator: SleepWakeCoordinator

    init(
        coordinator: SleepWakeCoordinator,
        center: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.center = center
        self.coordinator = coordinator
        super.init()

        center.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleEnvironmentDidChange),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleEnvironmentDidChange),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(handleEnvironmentDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        center.removeObserver(self)
    }

    @objc
    private func handleWillSleep() {
        logger.info("Observed NSWorkspace.willSleepNotification")
        coordinator.handleWillSleep()
    }

    @objc
    private func handleDidWake() {
        logger.info("Observed NSWorkspace.didWakeNotification")
        coordinator.handleDidWake()
    }

    @objc
    private func handleEnvironmentDidChange() {
        logger.info("Observed environment change notification")
        coordinator.handleEnvironmentDidChange()
    }
}
