import AppKit
import Foundation
import OSLog
import StayCore

// Design goal: keep app orchestration minimal and isolate policy choices
// (timing, readiness checks, persistence wiring) in one place.
@MainActor
final class StayApplicationDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.stay.app", category: "AppDelegate")
    private var statusItem: NSStatusItem?
    private var coordinator: SleepWakeCoordinator?
    private var sleepWakeObserver: SleepWakeObserver?
    private var snapshotService: AXWindowSnapshotService?
    private var repository: JSONSnapshotRepository?
    private var statusLine = "Starting"

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")
        configureStatusItem()
        startServices()
    }

    private func startServices() {
        let snapshotService = AXWindowSnapshotService(screenService: NSScreenCoordinateService())
        let repository = JSONSnapshotRepository(url: JSONSnapshotRepository.defaultURL())

        // Retry window restore until displays are verifiably awake.
        let coordinator = SleepWakeCoordinator(
            capturing: snapshotService,
            restoring: snapshotService,
            repository: repository,
            readinessChecker: DisplayWakeReadinessChecker(),
            scheduler: DispatchScheduler(queue: .main),
            wakeDelay: 1.0,
            retryInterval: 1.0,
            maxWaitAfterWake: 25.0
        )

        self.snapshotService = snapshotService
        self.repository = repository
        self.coordinator = coordinator
        self.sleepWakeObserver = SleepWakeObserver(coordinator: coordinator)

        if AccessibilityPermission.isTrusted(prompt: true) {
            logger.info("Accessibility permission already granted")
            updateStatus("Watching sleep/wake")
        } else {
            logger.warning("Accessibility permission not granted at launch")
            updateStatus("Enable Accessibility access")
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Stay"
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(
            makeMenuItem(title: "Capture Layout Now", action: #selector(captureLayoutNow), key: "c")
        )
        menu.addItem(
            makeMenuItem(title: "Restore Layout Now", action: #selector(restoreLayoutNow), key: "r")
        )
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Quit Stay", action: #selector(quit), key: "q"))

        statusItem?.menu = menu
    }

    private func makeMenuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatus(_ value: String) {
        statusLine = value
        rebuildMenu()
    }

    @objc private func captureLayoutNow() {
        guard let snapshotService, let repository else {
            updateStatus("Service unavailable")
            return
        }

        if !AccessibilityPermission.isTrusted(prompt: true) {
            updateStatus("Accessibility access needed")
            return
        }

        let snapshots = snapshotService.capture()
        guard !snapshots.isEmpty else {
            logger.warning("Manual capture found no movable windows")
            updateStatus("No movable windows found")
            return
        }

        repository.save(snapshots)
        logger.info("Manual capture saved \(snapshots.count, privacy: .public) snapshot(s)")
        updateStatus("Captured \(snapshots.count) window(s)")
    }

    @objc private func restoreLayoutNow() {
        guard let coordinator, let repository else {
            updateStatus("Service unavailable")
            return
        }

        if !AccessibilityPermission.isTrusted(prompt: true) {
            updateStatus("Accessibility access needed")
            return
        }

        let snapshots = repository.load()
        guard !snapshots.isEmpty else {
            logger.warning("Manual restore requested with no saved layout")
            updateStatus("No saved layout")
            return
        }

        // Reuse the coordinator's deferred-space state machine so windows hidden
        // on inactive workspaces remain pending until that workspace becomes active.
        coordinator.handleRestoreRequested(with: snapshots)
        logger.info(
            "Manual restore scheduled for \(snapshots.count, privacy: .public) snapshot(s)")
        updateStatus("Restoring \(snapshots.count) window(s)")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
