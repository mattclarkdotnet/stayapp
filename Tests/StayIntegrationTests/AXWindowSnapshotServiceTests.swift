import Foundation
import Testing

@testable import Stay
@testable import StayCore

@Suite("AXWindowSnapshotService")
struct AXWindowSnapshotServiceTests {
    @Test("Snapshots targeting unavailable displays are deferred instead of restored")
    func snapshotsWithUnavailableDisplaysArePartitionedOut() {
        let primary = sampleSnapshot(title: "Primary", index: 0, screenDisplayID: 1)
        let secondary = sampleSnapshot(title: "Secondary", index: 1, screenDisplayID: 2)

        let partition = AXWindowSnapshotService.partitionSnapshotsByAvailableDisplays(
            [primary, secondary],
            activeDisplayIDs: [1]
        )

        #expect(partition.eligible == [primary])
        #expect(partition.unavailable == [secondary])
    }

    @Test("Snapshots without saved display IDs stay eligible")
    func snapshotsWithoutSavedDisplayIDsRemainEligible() {
        let unknown = sampleSnapshot(title: "Unknown", index: 0, screenDisplayID: nil)

        let partition = AXWindowSnapshotService.partitionSnapshotsByAvailableDisplays(
            [unknown],
            activeDisplayIDs: [1]
        )

        #expect(partition.eligible == [unknown])
        #expect(partition.unavailable.isEmpty)
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
