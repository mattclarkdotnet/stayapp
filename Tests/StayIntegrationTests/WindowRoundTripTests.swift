import CoreGraphics
import Foundation
import Testing

@testable import StayCore

@Suite("WindowRoundTrip")
struct WindowRoundTripTests {
    @Test("Single window round-trip restores frame and display")
    func singleWindowRoundTripRestoresFrameAndDisplay() {
        let controller = FixtureWindowController()
        let service = FixtureWindowSnapshotService(controller: controller)

        let windowID = controller.createWindow(
            appPID: 1001,
            appBundleID: "com.example.notes",
            appName: "Notes",
            title: "Notes",
            frame: CGRect(x: 1200, y: 140, width: 800, height: 600)
        )

        let baseline = service.capture()
        #expect(baseline.count == 1)
        #expect(baseline[0].screenDisplayID == 5)

        controller.setFrame(
            for: windowID, frame: CGRect(x: 120, y: 180, width: 760, height: 540))
        #expect(controller.window(id: windowID)?.displayID == 1)

        let result = service.restore(from: baseline)
        #expect(result.movedWindowCount == 1)
        #expect(result.alreadyAlignedCount == 0)
        #expect(result.recoverableFailureCount == 0)
        #expect(result.deferredSnapshotCount == 0)
        #expect(result.isComplete)

        let restored = controller.window(id: windowID)
        #expect(restored?.frame == CGRect(x: 1200, y: 140, width: 800, height: 600))
        #expect(restored?.displayID == 5)
    }

    @Test("Multi-window round-trip restores all windows after perturbation")
    func multiWindowRoundTripRestoresAllWindows() {
        let controller = FixtureWindowController()
        let service = FixtureWindowSnapshotService(controller: controller)

        let first = controller.createWindow(
            appPID: 2002,
            appBundleID: "com.example.browser",
            appName: "Browser",
            title: "A",
            frame: CGRect(x: 90, y: 80, width: 900, height: 700)
        )
        let second = controller.createWindow(
            appPID: 2002,
            appBundleID: "com.example.browser",
            appName: "Browser",
            title: "B",
            frame: CGRect(x: 1220, y: 120, width: 900, height: 700)
        )
        let third = controller.createWindow(
            appPID: 2002,
            appBundleID: "com.example.browser",
            appName: "Browser",
            title: "C",
            frame: CGRect(x: 1180, y: 910, width: 640, height: 480)
        )

        let baseline = service.capture()
        #expect(baseline.count == 3)

        controller.setFrame(for: first, frame: CGRect(x: 1210, y: 90, width: 900, height: 700))
        controller.setFrame(for: second, frame: CGRect(x: 80, y: 120, width: 900, height: 700))
        controller.setFrame(for: third, frame: CGRect(x: 200, y: 880, width: 640, height: 480))

        let result = service.restore(from: baseline)
        #expect(result.movedWindowCount == 3)
        #expect(result.recoverableFailureCount == 0)
        #expect(result.isComplete)

        let after = controller.windows(forAppPID: 2002)
        #expect(after.count == 3)
        let frames = Set(after.map(\.frame))
        let expected = Set(baseline.map { $0.frame.cgRect })
        #expect(frames == expected)
    }

    @Test("Untitled tool windows round-trip restores after delayed exposure")
    func untitledToolWindowsRoundTripWithDelayedExposure() {
        let controller = FixtureWindowController()
        let service = FixtureWindowSnapshotService(controller: controller)

        let w1 = controller.createWindow(
            appPID: 3003,
            appBundleID: "org.freecad.FreeCAD",
            appName: "FreeCAD",
            title: nil,
            frame: CGRect(x: 80, y: 140, width: 420, height: 740)
        )
        let w2 = controller.createWindow(
            appPID: 3003,
            appBundleID: "org.freecad.FreeCAD",
            appName: "FreeCAD",
            title: nil,
            frame: CGRect(x: 560, y: 140, width: 420, height: 740)
        )
        let w3 = controller.createWindow(
            appPID: 3003,
            appBundleID: "org.freecad.FreeCAD",
            appName: "FreeCAD",
            title: nil,
            frame: CGRect(x: 1220, y: 140, width: 420, height: 740)
        )

        let baseline = service.capture()
        #expect(baseline.count == 3)

        controller.setFrame(for: w1, frame: CGRect(x: 1080, y: 120, width: 420, height: 740))
        controller.setFrame(for: w2, frame: CGRect(x: 1120, y: 130, width: 420, height: 740))
        controller.setFrame(for: w3, frame: CGRect(x: 1160, y: 140, width: 420, height: 740))

        controller.setVisibleWindowCount(appPID: 3003, count: 1)
        let deferredResult = service.restore(from: baseline)
        #expect(deferredResult.movedWindowCount == 0)
        #expect(deferredResult.recoverableFailureCount == 3)
        #expect(deferredResult.deferredSnapshotCount == 3)
        #expect(!deferredResult.isComplete)

        controller.setVisibleWindowCount(appPID: 3003, count: 3)
        let restoredResult = service.restore(from: baseline)
        #expect(restoredResult.movedWindowCount == 3)
        #expect(restoredResult.recoverableFailureCount == 0)
        #expect(restoredResult.isComplete)

        let frames = Set(controller.windows(forAppPID: 3003).map(\.frame))
        let expected = Set(baseline.map { $0.frame.cgRect })
        #expect(frames == expected)
    }

    @Test("Finder round-trip restores target display without forcing per-display size replay")
    func finderRoundTripRestoresTargetDisplay() {
        let controller = FixtureWindowController()
        let service = FixtureWindowSnapshotService(controller: controller)

        let recent = controller.createWindow(
            appPID: 4004,
            appBundleID: "com.apple.finder",
            appName: "Finder",
            title: "Recent",
            frame: CGRect(x: 120, y: 120, width: 960, height: 700)
        )
        let untitled = controller.createWindow(
            appPID: 4004,
            appBundleID: "com.apple.finder",
            appName: "Finder",
            title: nil,
            frame: CGRect(x: 1260, y: 120, width: 840, height: 620)
        )

        let baseline = service.capture()
        #expect(baseline.count == 2)
        #expect(controller.window(id: recent)?.displayID == 1)
        #expect(controller.window(id: untitled)?.displayID == 5)

        // Perturb onto primary display with a different size to model Finder's
        // per-display size memory behavior.
        controller.setFrame(
            for: untitled, frame: CGRect(x: 180, y: 140, width: 700, height: 500))
        #expect(controller.window(id: untitled)?.displayID == 1)

        let result = service.restore(from: baseline)
        #expect(result.recoverableFailureCount == 0)
        #expect(result.movedWindowCount == 1)
        #expect(result.alreadyAlignedCount == 1)
        #expect(result.isComplete)

        let restoredUntitled = controller.window(id: untitled)
        #expect(restoredUntitled?.displayID == 5)
        #expect(restoredUntitled?.frame.width == 700)
        #expect(restoredUntitled?.frame.height == 500)
    }
}

private struct FixtureWindow: Equatable {
    let id: Int
    let appPID: Int32
    let appBundleID: String?
    let appName: String
    let title: String?
    var frame: CGRect
}

private final class FixtureWindowController {
    private var nextID = 1
    private var windowsByID: [Int: FixtureWindow] = [:]
    private var visibleCountByPID: [Int32: Int] = [:]

    @discardableResult
    func createWindow(
        appPID: Int32,
        appBundleID: String?,
        appName: String,
        title: String?,
        frame: CGRect
    ) -> Int {
        let id = nextID
        nextID += 1
        windowsByID[id] = FixtureWindow(
            id: id,
            appPID: appPID,
            appBundleID: appBundleID,
            appName: appName,
            title: title,
            frame: frame
        )
        return id
    }

    func setFrame(for id: Int, frame: CGRect) {
        guard var window = windowsByID[id] else {
            return
        }
        window.frame = frame
        windowsByID[id] = window
    }

    func setVisibleWindowCount(appPID: Int32, count: Int) {
        visibleCountByPID[appPID] = max(0, count)
    }

    func window(id: Int) -> FixtureWindowView? {
        guard let window = windowsByID[id] else {
            return nil
        }
        return FixtureWindowView(window: window, displayID: displayID(for: window.frame))
    }

    func windows(forAppPID appPID: Int32) -> [FixtureWindowView] {
        windowsByID.values
            .filter { $0.appPID == appPID }
            .sorted { $0.id < $1.id }
            .map { FixtureWindowView(window: $0, displayID: displayID(for: $0.frame)) }
    }

    func snapshots() -> [WindowSnapshot] {
        let grouped = Dictionary(grouping: windowsByID.values, by: \.appPID)
        var snapshots: [WindowSnapshot] = []

        for pid in grouped.keys.sorted() {
            let windows = grouped[pid, default: []].sorted { $0.id < $1.id }
            for (index, window) in windows.enumerated() {
                snapshots.append(
                    WindowSnapshot(
                        appPID: window.appPID,
                        appBundleID: window.appBundleID,
                        appName: window.appName,
                        windowTitle: window.title,
                        windowIndex: index,
                        frame: CodableRect(window.frame),
                        screenDisplayID: displayID(for: window.frame)
                    )
                )
            }
        }

        return snapshots
    }

    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult {
        var moved = 0
        var aligned = 0
        var failures = 0
        var deferred = 0

        let groupedSnapshots = Dictionary(grouping: snapshots, by: \.appPID)

        for (pid, appSnapshots) in groupedSnapshots {
            let allWindows = windowsByID.values
                .filter { $0.appPID == pid }
                .sorted { $0.id < $1.id }
            let visibleCount = min(visibleCountByPID[pid] ?? allWindows.count, allWindows.count)
            let visibleWindowIDs = allWindows.prefix(visibleCount).map(\.id)

            let allUntitled = appSnapshots.allSatisfy {
                $0.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            }

            if allUntitled, visibleCount < appSnapshots.count {
                failures += appSnapshots.count
                deferred += appSnapshots.count
                continue
            }

            var unusedIDs = Set(visibleWindowIDs)

            for snapshot in appSnapshots.sorted(by: { $0.windowIndex < $1.windowIndex }) {
                guard
                    let matchedID = bestMatchWindowID(
                        for: snapshot,
                        candidateIDs: unusedIDs
                    )
                else {
                    failures += 1
                    continue
                }

                unusedIDs.remove(matchedID)
                guard let liveWindow = windowsByID[matchedID] else {
                    failures += 1
                    continue
                }

                let targetFrame = snapshot.frame.cgRect
                if snapshot.appBundleID == "com.apple.finder" {
                    if let targetDisplayID = snapshot.screenDisplayID,
                        displayID(for: liveWindow.frame) == targetDisplayID
                    {
                        aligned += 1
                        continue
                    }

                    // Finder remembers different window sizes per display/space.
                    // Restore target display by moving origin while keeping size.
                    setFrame(
                        for: matchedID,
                        frame: CGRect(
                            origin: targetFrame.origin,
                            size: liveWindow.frame.size
                        )
                    )
                    moved += 1
                    continue
                }

                if approximatelyEqual(liveWindow.frame, targetFrame) {
                    aligned += 1
                    continue
                }

                setFrame(for: matchedID, frame: targetFrame)
                moved += 1
            }
        }

        return WindowRestoreResult(
            isComplete: failures == 0,
            movedWindowCount: moved,
            alreadyAlignedCount: aligned,
            recoverableFailureCount: failures,
            deferredSnapshotCount: deferred
        )
    }

    private func bestMatchWindowID(for snapshot: WindowSnapshot, candidateIDs: Set<Int>) -> Int? {
        let candidates = candidateIDs.compactMap { id -> (Int, FixtureWindow)? in
            guard let window = windowsByID[id] else {
                return nil
            }
            return (id, window)
        }

        if let title = snapshot.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            if let titleMatch = candidates.first(where: {
                ($0.1.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == title.lowercased()
            }) {
                return titleMatch.0
            }
        }

        return candidates.min(by: { lhs, rhs in
            frameDistance(lhs.1.frame, snapshot.frame.cgRect)
                < frameDistance(rhs.1.frame, snapshot.frame.cgRect)
        })?.0
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool
    {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func displayID(for frame: CGRect) -> UInt32 {
        let centerX = frame.midX
        return centerX < 1000 ? 1 : 5
    }
}

private struct FixtureWindowView: Equatable {
    let id: Int
    let appPID: Int32
    let title: String?
    let frame: CGRect
    let displayID: UInt32

    init(window: FixtureWindow, displayID: UInt32) {
        self.id = window.id
        self.appPID = window.appPID
        self.title = window.title
        self.frame = window.frame
        self.displayID = displayID
    }
}

private final class FixtureWindowSnapshotService: WindowSnapshotCapturing, WindowSnapshotRestoring {
    private let controller: FixtureWindowController

    init(controller: FixtureWindowController) {
        self.controller = controller
    }

    func capture() -> [WindowSnapshot] {
        controller.snapshots()
    }

    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult {
        controller.restore(from: snapshots)
    }
}
