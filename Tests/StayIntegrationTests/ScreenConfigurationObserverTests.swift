import AppKit
import Foundation
import Testing

@testable import Stay

@Suite("ScreenConfigurationObserver")
@MainActor
struct ScreenConfigurationObserverTests {
    @Test("Screen parameter change invalidates persisted and pending snapshots")
    func screenParameterChangeInvalidatesSnapshots() {
        let center = NotificationCenter()
        let repository = SpySnapshotDisplayInvalidator()
        let pendingInvalidator = SpyPendingSnapshotDisplayInvalidator()
        let displayInventory = StubDisplayInventory(displayIDs: [1, 3])
        let notificationName = Notification.Name("ScreenConfigurationObserverTests.didChange")

        let observer = ScreenConfigurationObserver(
            repository: repository,
            pendingSnapshotInvalidator: pendingInvalidator,
            displayInventory: displayInventory,
            center: center,
            notificationName: notificationName
        )

        center.post(name: notificationName, object: nil)
        withExtendedLifetime(observer) {}

        #expect(repository.invalidatedDisplaySets == [[1, 3]])
        #expect(pendingInvalidator.invalidatedDisplaySets == [[1, 3]])
    }
}

private final class SpySnapshotDisplayInvalidator: SnapshotDisplayInvalidating {
    var invalidatedDisplaySets: [Set<UInt32>] = []

    func invalidateSnapshots(keepingDisplayIDs activeDisplayIDs: Set<UInt32>) -> Int {
        invalidatedDisplaySets.append(activeDisplayIDs)
        return 0
    }
}

private final class SpyPendingSnapshotDisplayInvalidator: PendingSnapshotDisplayInvalidating {
    var invalidatedDisplaySets: [Set<UInt32>] = []

    func handleDisplayConfigurationChanged(activeDisplayIDs: Set<UInt32>) -> Int {
        invalidatedDisplaySets.append(activeDisplayIDs)
        return 0
    }
}

private struct StubDisplayInventory: DisplayInventoryReading {
    let displayIDs: Set<UInt32>

    func currentDisplayIDs() -> Set<UInt32> {
        displayIDs
    }
}
