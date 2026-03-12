import Foundation
import Testing

@testable import StayCore

@Suite("JSONSnapshotRepository")
struct JSONSnapshotRepositoryTests {
    @Test("Invalidate snapshots removes entries for disconnected displays")
    func invalidateSnapshotsRemovesDisconnectedDisplays() throws {
        let fileURL = makeRepositoryURL()
        let repository = JSONSnapshotRepository(url: fileURL)

        repository.save([
            sampleSnapshot(title: "Primary", index: 0, screenDisplayID: 1),
            sampleSnapshot(title: "Secondary", index: 1, screenDisplayID: 2),
            sampleSnapshot(title: "Unknown", index: 2, screenDisplayID: nil),
        ])

        let removedCount = repository.invalidateSnapshots(keepingDisplayIDs: [1])
        let remainingSnapshots = repository.load()

        #expect(removedCount == 1)
        #expect(remainingSnapshots.count == 2)
        #expect(remainingSnapshots.map(\.windowTitle) == ["Primary", "Unknown"])
    }

    @Test("Invalidate snapshots is a no-op when all display IDs are still active")
    func invalidateSnapshotsNoopWhenDisplaysRemain() throws {
        let fileURL = makeRepositoryURL()
        let repository = JSONSnapshotRepository(url: fileURL)

        let snapshots = [
            sampleSnapshot(title: "Primary", index: 0, screenDisplayID: 1),
            sampleSnapshot(title: "Secondary", index: 1, screenDisplayID: 2),
        ]
        repository.save(snapshots)

        let removedCount = repository.invalidateSnapshots(keepingDisplayIDs: [1, 2, 3])

        #expect(removedCount == 0)
        #expect(repository.load() == snapshots)
    }

    private func makeRepositoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JSONSnapshotRepositoryTests-\(UUID().uuidString)")
            .appendingPathComponent("window-layout.json")
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
            frame: CodableRect(x: 100, y: 100, width: 800, height: 600),
            screenDisplayID: screenDisplayID
        )
    }
}
