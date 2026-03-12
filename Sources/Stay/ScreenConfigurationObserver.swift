import AppKit
import Foundation
import OSLog
import StayCore

protocol DisplayInventoryReading {
    func currentDisplayIDs() -> Set<UInt32>
}

protocol SnapshotDisplayInvalidating {
    @discardableResult
    func invalidateSnapshots(keepingDisplayIDs activeDisplayIDs: Set<UInt32>) -> Int
}

protocol PendingSnapshotDisplayInvalidating {
    @discardableResult
    func handleDisplayConfigurationChanged(activeDisplayIDs: Set<UInt32>) -> Int
}

extension JSONSnapshotRepository: SnapshotDisplayInvalidating {}
extension SleepWakeCoordinator: PendingSnapshotDisplayInvalidating {}

// Design goal: react to awake-time display topology changes at the app boundary,
// trimming stale persisted targets before later restore flows can reuse them.
@MainActor
final class ScreenConfigurationObserver: NSObject {
    private let logger = Logger(subsystem: "com.stay.app", category: "ScreenConfigurationObserver")
    private let center: NotificationCenter
    private let repository: any SnapshotDisplayInvalidating
    private let pendingSnapshotInvalidator: (any PendingSnapshotDisplayInvalidating)?
    private let displayInventory: any DisplayInventoryReading
    private let notificationName: Notification.Name

    init(
        repository: any SnapshotDisplayInvalidating,
        pendingSnapshotInvalidator: (any PendingSnapshotDisplayInvalidating)? = nil,
        displayInventory: any DisplayInventoryReading,
        center: NotificationCenter = .default,
        notificationName: Notification.Name = NSApplication.didChangeScreenParametersNotification
    ) {
        self.center = center
        self.repository = repository
        self.pendingSnapshotInvalidator = pendingSnapshotInvalidator
        self.displayInventory = displayInventory
        self.notificationName = notificationName
        super.init()

        center.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange),
            name: notificationName,
            object: nil
        )
    }

    deinit {
        center.removeObserver(self)
    }

    @objc
    private func handleScreenParametersDidChange() {
        let activeDisplayIDs = displayInventory.currentDisplayIDs()
        let invalidatedPersistedCount = repository.invalidateSnapshots(
            keepingDisplayIDs: activeDisplayIDs)
        let invalidatedPendingCount =
            pendingSnapshotInvalidator?.handleDisplayConfigurationChanged(
                activeDisplayIDs: activeDisplayIDs) ?? 0

        logger.info(
            "Observed screen-parameter change; activeDisplays=\(activeDisplayIDs.count, privacy: .public) invalidatedPersistedSnapshots=\(invalidatedPersistedCount, privacy: .public) invalidatedPendingSnapshots=\(invalidatedPendingCount, privacy: .public)"
        )
    }
}
