import AppKit
import Foundation
import Testing

@testable import Stay
@testable import StayCore

@Suite("ScreenConfigurationObserver")
@MainActor
struct ScreenConfigurationObserverTests {
    @Test("Screen parameter change suspends then reactivates same-display snapshots")
    func screenParameterChangeSuspendsAndReactivatesSnapshots() {
        let center = NotificationCenter()
        let repository = InMemorySnapshotStore(snapshots: [
            sampleSnapshot(title: "Primary", index: 0, screenDisplayID: 1),
            sampleSnapshot(title: "Secondary", index: 1, screenDisplayID: 2),
        ])
        let pendingInvalidator = SpyPendingSnapshotDisplayInvalidator()
        let reactivatedRestorer = SpyReactivatedSnapshotRestorer()
        let environmentChangeHandler = SpyRestoreEnvironmentChangeHandler()
        let displayInventory = MutableDisplayInventory(displayIDs: [1, 2])
        let notificationName = Notification.Name("ScreenConfigurationObserverTests.didChange")

        let observer = ScreenConfigurationObserver(
            snapshotReader: repository,
            snapshotWriter: repository,
            pendingSnapshotInvalidator: pendingInvalidator,
            reactivatedSnapshotRestorer: reactivatedRestorer,
            restoreEnvironmentChangeHandler: environmentChangeHandler,
            displayInventory: displayInventory,
            center: center,
            notificationName: notificationName
        )

        displayInventory.displayIDs = [1]
        center.post(name: notificationName, object: nil)

        #expect(repository.savedSnapshots.map(\.windowTitle) == ["Primary"])
        #expect(pendingInvalidator.invalidatedDisplaySets == [[1]])
        #expect(reactivatedRestorer.calls.isEmpty)
        #expect(environmentChangeHandler.calls == [.unspecified])

        displayInventory.displayIDs = [1, 2]
        center.post(name: notificationName, object: nil)
        withExtendedLifetime(observer) {}

        #expect(Set(repository.savedSnapshots.compactMap(\.screenDisplayID)) == [1, 2])
        #expect(pendingInvalidator.invalidatedDisplaySets == [[1], [1, 2]])
        #expect(reactivatedRestorer.calls.count == 1)
        #expect(reactivatedRestorer.calls[0].map(\.windowTitle) == ["Secondary"])
        #expect(environmentChangeHandler.calls == [.unspecified, .unspecified])
    }
}

private final class InMemorySnapshotStore: SnapshotStoreReading, SnapshotStoreWriting {
    var savedSnapshots: [WindowSnapshot]

    init(snapshots: [WindowSnapshot]) {
        self.savedSnapshots = snapshots
    }

    func loadSnapshots() -> [WindowSnapshot] {
        savedSnapshots
    }

    func saveSnapshots(_ snapshots: [WindowSnapshot]) {
        savedSnapshots = snapshots
    }
}

private final class SpyPendingSnapshotDisplayInvalidator: PendingSnapshotDisplaySuspending {
    var invalidatedDisplaySets: [Set<UInt32>] = []

    func handleDisplayConfigurationChanged(activeDisplayIDs: Set<UInt32>) -> Int {
        invalidatedDisplaySets.append(activeDisplayIDs)
        return 0
    }
}

private final class SpyReactivatedSnapshotRestorer: ReactivatedSnapshotRestoring {
    var calls: [[WindowSnapshot]] = []

    func handleReactivatedSnapshotsAvailable(_ snapshots: [WindowSnapshot]) {
        calls.append(snapshots)
    }
}

private final class SpyRestoreEnvironmentChangeHandler: RestoreEnvironmentChangeHandling {
    var calls: [EnvironmentChangeKind] = []

    func handleEnvironmentDidChange(_ kind: EnvironmentChangeKind) {
        calls.append(kind)
    }
}

private final class MutableDisplayInventory: DisplayInventoryReading {
    var displayIDs: Set<UInt32>

    init(displayIDs: Set<UInt32>) {
        self.displayIDs = displayIDs
    }

    func currentDisplayIDs() -> Set<UInt32> {
        displayIDs
    }
}

private func sampleSnapshot(
    title: String,
    index: Int,
    screenDisplayID: UInt32?
) -> WindowSnapshot {
    WindowSnapshot(
        appPID: 123,
        appBundleID: "com.example.app",
        appName: "Example",
        windowTitle: title,
        windowIndex: index,
        frame: StayCore.CodableRect(x: 100, y: 100, width: 800, height: 600),
        screenDisplayID: screenDisplayID
    )
}
