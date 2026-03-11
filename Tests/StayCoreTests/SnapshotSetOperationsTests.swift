import Testing

@testable import StayCore

@Suite("SnapshotSetOperations")
struct SnapshotSetOperationsTests {
    @Test("Merge returns fallback when latest capture is empty")
    func mergeReturnsFallbackWhenLatestIsEmpty() {
        let fallback = [snapshot(bundleID: "com.apple.Safari", pid: 10, index: 0)]

        let merged = SnapshotSetOperations.mergeLatestWithFallback(
            latest: [],
            fallback: fallback
        )

        #expect(merged == fallback)
    }

    @Test("Merge returns latest when fallback is empty")
    func mergeReturnsLatestWhenFallbackIsEmpty() {
        let latest = [snapshot(bundleID: "com.apple.Mail", pid: 20, index: 0)]

        let merged = SnapshotSetOperations.mergeLatestWithFallback(
            latest: latest,
            fallback: []
        )

        #expect(merged == latest)
    }

    @Test("Merge prefers latest per app and keeps fallback for missing apps")
    func mergePrefersLatestPerAppAndKeepsFallbackForMissingApps() {
        let latest = [
            snapshot(bundleID: "com.apple.finder", pid: 100, index: 0),
            snapshot(bundleID: "com.apple.finder", pid: 100, index: 1),
        ]
        let fallback = [
            snapshot(bundleID: "com.apple.finder", pid: 99, index: 0),
            snapshot(bundleID: "com.apple.TextEdit", pid: 200, index: 0),
        ]

        let merged = SnapshotSetOperations.mergeLatestWithFallback(
            latest: latest,
            fallback: fallback
        )

        #expect(merged.contains(where: { $0.appBundleID == "com.apple.TextEdit" }))
        #expect(merged.filter { $0.appBundleID == "com.apple.finder" } == latest)
        #expect(merged.count == 3)
    }

    @Test("Merge uses bundle identity when PID changes")
    func mergeUsesBundleIdentityWhenPIDChanges() {
        let latest = [snapshot(bundleID: "org.freecad.FreeCAD", pid: 500, index: 0)]
        let fallback = [snapshot(bundleID: "org.freecad.FreeCAD", pid: 123, index: 0)]

        let merged = SnapshotSetOperations.mergeLatestWithFallback(
            latest: latest,
            fallback: fallback
        )

        #expect(merged == latest)
    }

    @Test("Merge falls back to PID identity when bundle ID is missing")
    func mergeFallsBackToPIDIdentityWhenBundleIDIsMissing() {
        let latest = [snapshot(bundleID: nil, pid: 77, index: 0)]
        let fallback = [
            snapshot(bundleID: nil, pid: 77, index: 1),
            snapshot(bundleID: nil, pid: 88, index: 0),
        ]

        let merged = SnapshotSetOperations.mergeLatestWithFallback(
            latest: latest,
            fallback: fallback
        )

        #expect(merged.count == 2)
        #expect(merged.contains(where: { $0.appPID == 88 }))
        #expect(merged.contains(where: { $0.appPID == 77 && $0.windowIndex == 0 }))
    }

    @Test("Remove resolved snapshots preserves pending order")
    func removeResolvedSnapshotsPreservesPendingOrder() {
        let one = snapshot(bundleID: "com.apple.finder", pid: 1, index: 0)
        let two = snapshot(bundleID: "com.apple.finder", pid: 1, index: 1)
        let three = snapshot(bundleID: "com.apple.finder", pid: 1, index: 2)

        let filtered = SnapshotSetOperations.removeResolved(
            from: [one, two, three],
            resolved: [two]
        )

        #expect(filtered == [one, three])
    }

    @Test("Remove resolved snapshots removes only matching multiplicity")
    func removeResolvedSnapshotsRemovesOnlyMatchingMultiplicity() {
        let duplicate = snapshot(bundleID: "com.apple.finder", pid: 1, index: 0)
        let other = snapshot(bundleID: "com.apple.finder", pid: 1, index: 1)

        let filtered = SnapshotSetOperations.removeResolved(
            from: [duplicate, duplicate, other],
            resolved: [duplicate]
        )

        #expect(filtered == [duplicate, other])
    }

    @Test("Remove resolved snapshots ignores unknown resolved entries")
    func removeResolvedSnapshotsIgnoresUnknownResolvedEntries() {
        let pending = [snapshot(bundleID: "com.apple.TextEdit", pid: 9, index: 0)]
        let unknown = [snapshot(bundleID: "com.apple.TextEdit", pid: 9, index: 1)]

        let filtered = SnapshotSetOperations.removeResolved(from: pending, resolved: unknown)

        #expect(filtered == pending)
    }

    private func snapshot(bundleID: String?, pid: Int32, index: Int) -> WindowSnapshot {
        WindowSnapshot(
            appPID: pid,
            appBundleID: bundleID,
            appName: "App",
            windowTitle: "Window \(index)",
            windowIndex: index,
            frame: CodableRect(x: 0, y: 0, width: 100, height: 100),
            screenDisplayID: 1
        )
    }
}
