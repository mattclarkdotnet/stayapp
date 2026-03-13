import AppKit
import Foundation
import OSLog
import StayCore

protocol DisplayInventoryReading {
    func currentDisplayIDs() -> Set<UInt32>
}

protocol SnapshotStoreReading {
    func loadSnapshots() -> [WindowSnapshot]
}

protocol SnapshotStoreWriting {
    func saveSnapshots(_ snapshots: [WindowSnapshot])
}

protocol PendingSnapshotDisplaySuspending {
    @discardableResult
    func handleDisplayConfigurationChanged(activeDisplayIDs: Set<UInt32>) -> Int
}

protocol ReactivatedSnapshotRestoring {
    func handleReactivatedSnapshotsAvailable(_ snapshots: [WindowSnapshot])
}

protocol RestoreEnvironmentChangeHandling {
    func handleEnvironmentDidChange(_ kind: EnvironmentChangeKind)
}

extension JSONSnapshotRepository: SnapshotStoreReading {
    func loadSnapshots() -> [WindowSnapshot] {
        load()
    }
}

extension JSONSnapshotRepository: SnapshotStoreWriting {
    func saveSnapshots(_ snapshots: [WindowSnapshot]) {
        save(snapshots)
    }
}

extension SleepWakeCoordinator: PendingSnapshotDisplaySuspending {}
extension SleepWakeCoordinator: ReactivatedSnapshotRestoring {}
extension SleepWakeCoordinator: RestoreEnvironmentChangeHandling {}

// Design goal: react to awake-time display topology changes at the app boundary,
// suspending targets for removed displays immediately and reactivating them if
// that same display returns while Stay is still awake.
@MainActor
final class ScreenConfigurationObserver: NSObject {
    private let logger = Logger(
        subsystem: "net.mattclark.stay", category: "ScreenConfigurationObserver")
    private let center: NotificationCenter
    private let snapshotReader: any SnapshotStoreReading
    private let snapshotWriter: any SnapshotStoreWriting
    private let pendingSnapshotInvalidator: (any PendingSnapshotDisplaySuspending)?
    private let reactivatedSnapshotRestorer: (any ReactivatedSnapshotRestoring)?
    private let restoreEnvironmentChangeHandler: (any RestoreEnvironmentChangeHandling)?
    private let displayInventory: any DisplayInventoryReading
    private let notificationName: Notification.Name
    private var previousActiveDisplayIDs: Set<UInt32>
    private var suspendedSnapshotsByDisplayID: [UInt32: [WindowSnapshot]] = [:]

    init(
        snapshotReader: any SnapshotStoreReading,
        snapshotWriter: any SnapshotStoreWriting,
        pendingSnapshotInvalidator: (any PendingSnapshotDisplaySuspending)? = nil,
        reactivatedSnapshotRestorer: (any ReactivatedSnapshotRestoring)? = nil,
        restoreEnvironmentChangeHandler: (any RestoreEnvironmentChangeHandling)? = nil,
        displayInventory: any DisplayInventoryReading,
        center: NotificationCenter = .default,
        notificationName: Notification.Name = NSApplication.didChangeScreenParametersNotification
    ) {
        self.center = center
        self.snapshotReader = snapshotReader
        self.snapshotWriter = snapshotWriter
        self.pendingSnapshotInvalidator = pendingSnapshotInvalidator
        self.reactivatedSnapshotRestorer = reactivatedSnapshotRestorer
        self.restoreEnvironmentChangeHandler = restoreEnvironmentChangeHandler
        self.displayInventory = displayInventory
        self.notificationName = notificationName
        self.previousActiveDisplayIDs = displayInventory.currentDisplayIDs()
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
        let removedDisplayIDs = previousActiveDisplayIDs.subtracting(activeDisplayIDs)
        let addedDisplayIDs = activeDisplayIDs.subtracting(previousActiveDisplayIDs)

        let suspendedPersistedSnapshots = suspendSnapshots(forRemovedDisplayIDs: removedDisplayIDs)
        let invalidatedPendingCount =
            pendingSnapshotInvalidator?.handleDisplayConfigurationChanged(
                activeDisplayIDs: activeDisplayIDs) ?? 0
        let reactivatedSnapshots = reactivateSnapshots(forAddedDisplayIDs: addedDisplayIDs)

        if !reactivatedSnapshots.isEmpty {
            reactivatedSnapshotRestorer?.handleReactivatedSnapshotsAvailable(reactivatedSnapshots)
        }

        previousActiveDisplayIDs = activeDisplayIDs
        restoreEnvironmentChangeHandler?.handleEnvironmentDidChange(.unspecified)

        logger.info(
            "Observed screen-parameter change; activeDisplays=\(activeDisplayIDs.count, privacy: .public) suspendedPersistedSnapshots=\(suspendedPersistedSnapshots, privacy: .public) invalidatedPendingSnapshots=\(invalidatedPendingCount, privacy: .public) reactivatedPersistedSnapshots=\(reactivatedSnapshots.count, privacy: .public)"
        )
    }

    private func suspendSnapshots(forRemovedDisplayIDs removedDisplayIDs: Set<UInt32>) -> Int {
        guard !removedDisplayIDs.isEmpty else {
            return 0
        }

        let snapshots = snapshotReader.loadSnapshots()
        guard !snapshots.isEmpty else {
            return 0
        }

        var retainedSnapshots: [WindowSnapshot] = []
        var suspendedCount = 0

        for snapshot in snapshots {
            guard
                let screenDisplayID = snapshot.screenDisplayID,
                removedDisplayIDs.contains(screenDisplayID)
            else {
                retainedSnapshots.append(snapshot)
                continue
            }

            suspendedSnapshotsByDisplayID[screenDisplayID, default: []].append(snapshot)
            suspendedCount += 1
        }

        if suspendedCount > 0 {
            snapshotWriter.saveSnapshots(retainedSnapshots)
        }

        return suspendedCount
    }

    private func reactivateSnapshots(forAddedDisplayIDs addedDisplayIDs: Set<UInt32>)
        -> [WindowSnapshot]
    {
        guard !addedDisplayIDs.isEmpty else {
            return []
        }

        var reactivatedSnapshots: [WindowSnapshot] = []
        for displayID in addedDisplayIDs {
            guard let suspended = suspendedSnapshotsByDisplayID.removeValue(forKey: displayID)
            else {
                continue
            }
            reactivatedSnapshots.append(contentsOf: suspended)
        }

        guard !reactivatedSnapshots.isEmpty else {
            return []
        }

        var mergedSnapshots = snapshotReader.loadSnapshots()
        for snapshot in reactivatedSnapshots where !mergedSnapshots.contains(snapshot) {
            mergedSnapshots.append(snapshot)
        }
        snapshotWriter.saveSnapshots(mergedSnapshots)
        return reactivatedSnapshots
    }
}
