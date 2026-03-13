import AppKit
import Foundation
import OSLog
import StayCore

// Design goal: keep app orchestration minimal and isolate policy choices
// (timing, readiness checks, persistence wiring) in one place.
@MainActor
final class StayApplicationDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "net.mattclark.stay", category: "AppDelegate")
    private let separateSpacesPolicy: SeparateSpacesSuspensionPolicy
    private let notifierFactory: () -> any StayUserNotifying
    private let launchAtLoginController: any LaunchAtLoginControlling
    private let launchAtLoginDefaults: any LaunchAtLoginPreferenceStoring
    private var statusItem: NSStatusItem?
    private var coordinator: SleepWakeCoordinator?
    private var sleepWakeObserver: SleepWakeObserver?
    private var screenConfigurationObserver: ScreenConfigurationObserver?
    private var snapshotService: AXWindowSnapshotService?
    private var repository: JSONSnapshotRepository?
    private var statusLine = "Starting"
    private var isPausedForSeparateSpaces = false
    private var hasSentSeparateSpacesNotification = false

    init(
        separateSpacesPreferenceReader: any SeparateSpacesPreferenceReading =
            MacOSSeparateSpacesPreferenceReader(),
        notifierFactory: @escaping () -> any StayUserNotifying = { StayUserNotificationCenter() },
        launchAtLoginController: any LaunchAtLoginControlling = LaunchAtLoginController(),
        launchAtLoginDefaults: any LaunchAtLoginPreferenceStoring = UserDefaults.standard
    ) {
        self.separateSpacesPolicy = SeparateSpacesSuspensionPolicy(
            preferenceReader: separateSpacesPreferenceReader)
        self.notifierFactory = notifierFactory
        self.launchAtLoginController = launchAtLoginController
        self.launchAtLoginDefaults = launchAtLoginDefaults
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")
        configureStatusItem()
        configureDefaultLaunchAtLoginIfNeeded()
        startServices()
    }

    private func configureDefaultLaunchAtLoginIfNeeded() {
        let enabler = DefaultLaunchAtLoginEnabler(
            controller: launchAtLoginController,
            preferences: launchAtLoginDefaults
        )

        do {
            switch try enabler.configureIfNeeded() {
            case .enabledByDefault:
                logger.info("Launch at login enabled by default on first installed launch")
            case .alreadyConfigured, .unavailable:
                break
            }
        } catch {
            logger.error(
                "Default launch-at-login enable failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func startServices() {
        if applySeparateSpacesPolicyIfNeeded() {
            return
        }

        let screenService = NSScreenCoordinateService()
        let snapshotService = AXWindowSnapshotService(screenService: screenService)
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
        self.screenConfigurationObserver = ScreenConfigurationObserver(
            snapshotReader: repository,
            snapshotWriter: repository,
            pendingSnapshotInvalidator: coordinator,
            reactivatedSnapshotRestorer: coordinator,
            restoreEnvironmentChangeHandler: coordinator,
            displayInventory: screenService
        )

        if AccessibilityPermission.isTrusted(prompt: true) {
            logger.info("Accessibility permission already granted")
            updateStatus("Watching sleep/wake")
        } else {
            logger.warning("Accessibility permission not granted at launch")
            updateStatus("Enable Accessibility access")
        }
    }

    private func applySeparateSpacesPolicyIfNeeded() -> Bool {
        guard separateSpacesPolicy.shouldSuspendStay() else {
            isPausedForSeparateSpaces = false
            return false
        }

        isPausedForSeparateSpaces = true
        logger.info("Separate Spaces is enabled; standing down")
        updateStatus(SeparateSpacesSuspensionPolicy.suspendedStatusLine)

        if !hasSentSeparateSpacesNotification {
            notifierFactory().notifySeparateSpacesSuspended()
            hasSentSeparateSpacesNotification = true
        }

        return true
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: StayMenuPresentation.menuBarSymbolName,
                accessibilityDescription: StayMenuPresentation.menuBarAccessibilityDescription
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = StayMenuPresentation.menuBarAccessibilityDescription
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let presentation = StayMenuPresentation(
            statusDetail: statusLine,
            isPaused: isPausedForSeparateSpaces
        )

        let stateItem = NSMenuItem(title: presentation.stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        let detailItem = NSMenuItem(title: presentation.detailTitle, action: nil, keyEquivalent: "")
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        menu.addItem(.separator())
        let launchAtLoginStatus = launchAtLoginController.status()
        let launchAtLoginItem = makeMenuItem(
            title: "Launch At Login",
            action: #selector(toggleLaunchAtLogin),
            key: ""
        )
        launchAtLoginItem.state = launchAtLoginMenuState(for: launchAtLoginStatus)
        launchAtLoginItem.isEnabled = launchAtLoginStatus != .unavailable
        menu.addItem(launchAtLoginItem)

        if launchAtLoginStatus == .requiresApproval {
            let reviewItem = makeMenuItem(
                title: "Open Login Items Settings",
                action: #selector(openLoginItemsSettings),
                key: ""
            )
            menu.addItem(reviewItem)
        } else if launchAtLoginStatus == .unavailable {
            let infoItem = NSMenuItem(
                title: "Install Stay.app to enable launch at login",
                action: nil,
                keyEquivalent: ""
            )
            infoItem.isEnabled = false
            menu.addItem(infoItem)
        }

        menu.addItem(.separator())
        let captureItem = makeMenuItem(
            title: "Capture Layout Now",
            action: #selector(captureLayoutNow),
            key: "c"
        )
        captureItem.isEnabled = !isPausedForSeparateSpaces
        menu.addItem(captureItem)
        let restoreItem = makeMenuItem(
            title: "Restore Layout Now",
            action: #selector(restoreLayoutNow),
            key: "r"
        )
        restoreItem.isEnabled = !isPausedForSeparateSpaces
        menu.addItem(restoreItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Quit Stay", action: #selector(quit), key: "q"))

        statusItem?.menu = menu
        statusItem?.button?.toolTip =
            "\(StayMenuPresentation.menuBarAccessibilityDescription): \(presentation.stateTitle)"
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

    private func launchAtLoginMenuState(for status: LaunchAtLoginStatus) -> NSControl.StateValue {
        switch status {
        case .enabled:
            return .on
        case .disabled, .unavailable:
            return .off
        case .requiresApproval:
            return .mixed
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let currentStatus = launchAtLoginController.status()
        let shouldEnable = currentStatus == .disabled

        do {
            try launchAtLoginController.setEnabled(shouldEnable)
            if shouldEnable {
                updateStatus("Launch at login enabled")
            } else {
                updateStatus("Launch at login disabled")
            }
        } catch LaunchAtLoginError.unavailable {
            updateStatus("Install Stay.app to enable login launch")
        } catch {
            logger.error(
                "Launch-at-login change failed: \(String(describing: error), privacy: .public)")
            updateStatus("Launch at login update failed")
        }
    }

    @objc private func openLoginItemsSettings() {
        launchAtLoginController.openSystemSettings()
        updateStatus("Review Login Items settings")
    }

    @objc private func captureLayoutNow() {
        guard !isPausedForSeparateSpaces else {
            updateStatus(SeparateSpacesSuspensionPolicy.suspendedStatusLine)
            return
        }

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
        guard !isPausedForSeparateSpaces else {
            updateStatus(SeparateSpacesSuspensionPolicy.suspendedStatusLine)
            return
        }

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
