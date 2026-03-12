import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Design intent: isolate wake-cycle verification/readiness and iterative restore
// logic from scenario setup/orchestration.
extension WakeCycleScenarioRunner {
    func verifyTrackedWindows(
        scenario: Scenario,
        _ trackedWindows: [TrackedWindow],
        pids: [Int32]
    ) -> Bool {
        let windows = liveWindows(pids: pids)
        guard !windows.isEmpty else {
            return false
        }

        for tracked in trackedWindows {
            guard let matched = bestWindowForTracked(tracked, windows: windows) else {
                return false
            }
            if !isAligned(scenario: scenario, tracked: tracked, live: matched) {
                return false
            }
        }

        return true
    }

    func verificationMismatches(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32]
    ) -> [String] {
        let windows = liveWindows(pids: pids)
        if windows.isEmpty {
            return ["no live windows exposed for app pids=\(pids)"]
        }

        var issues: [String] = []
        for tracked in trackedWindows {
            guard let matched = bestWindowForTracked(tracked, windows: windows) else {
                issues.append("missing window for title hint '\(tracked.titleHint)'")
                continue
            }
            guard let currentDisplay = displayID(for: matched.frame) else {
                issues.append("could not infer display for title hint '\(tracked.titleHint)'")
                continue
            }
            if !isAligned(scenario: scenario, tracked: tracked, live: matched) {
                let expected = tracked.expectedFrame.cgRect
                issues.append(
                    "window '\(tracked.titleHint)' on display \(currentDisplay) frame \(frameSummary(matched.frame)); expected display \(tracked.expectedDisplayID) frame \(frameSummary(expected))"
                )
            }
        }

        return issues
    }

    func bestWindowForTracked(_ tracked: TrackedWindow, windows: [LiveWindow]) -> LiveWindow? {
        let titleHint = tracked.titleHint
        let scopedWindows: [LiveWindow]
        if let bundleID = tracked.appBundleID {
            let scoped = windows.filter { $0.appBundleID == bundleID }
            scopedWindows = scoped.isEmpty ? windows : scoped
        } else {
            scopedWindows = windows
        }

        let byTitle = scopedWindows.first { window in
            normalized(window.title)?.contains(titleHint) == true
        }
        if let byTitle {
            return byTitle
        }

        let expectedFrame = tracked.expectedFrame.cgRect
        return scopedWindows.min { lhs, rhs in
            frameDistance(lhs.frame, expectedFrame) < frameDistance(rhs.frame, expectedFrame)
        }
    }

    func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    func waitForVerificationWithProgress(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date.distantPast

        while Date() < deadline {
            let mismatches = verificationMismatches(
                scenario: scenario,
                trackedWindows: trackedWindows,
                pids: pids
            )
            if mismatches.isEmpty {
                print("Verification passed.")
                return true
            }

            if Date() >= nextLog {
                print("Verification pending (\(mismatches.count) mismatch(es)):")
                mismatches.forEach { print("  - \($0)") }
                nextLog = Date().addingTimeInterval(1.0)
            }

            sleepRunLoop(0.2)
        }

        return verifyTrackedWindows(scenario: scenario, trackedWindows, pids: pids)
    }

    func restoreTrackedWindowsWithProgress(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            let mismatches = verificationMismatches(
                scenario: scenario,
                trackedWindows: trackedWindows,
                pids: pids
            )
            if mismatches.isEmpty {
                print("Restore converged before timeout.")
                return true
            }

            attempt += 1
            print("Restore attempt \(attempt) (\(mismatches.count) mismatch(es))")

            let result = applyTrackedFrames(
                scenario: scenario, trackedWindows: trackedWindows, pids: pids)
            print(
                "  moved=\(result.moved) aligned=\(result.aligned) failures=\(result.failures) unmatched=\(result.unmatched)"
            )

            if result.failures > 0 || result.unmatched > 0 {
                let latest = verificationMismatches(
                    scenario: scenario,
                    trackedWindows: trackedWindows,
                    pids: pids
                )
                latest.forEach { print("  - \($0)") }
            }

            sleepRunLoop(1.0)
        }

        return verifyTrackedWindows(scenario: scenario, trackedWindows, pids: pids)
    }

    func applyTrackedFrames(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32]
    ) -> (moved: Int, aligned: Int, failures: Int, unmatched: Int) {
        let windows = liveWindows(pids: pids)
        let assignments = assignLiveWindows(trackedWindows, to: windows)
        var moved = 0
        var aligned = 0
        var failures = 0

        for (tracked, live) in assignments {
            guard displayID(for: live.frame) != nil else {
                failures += 1
                continue
            }

            if isAligned(scenario: scenario, tracked: tracked, live: live) {
                aligned += 1
                continue
            }

            let targetFrame = restoreFrame(for: scenario, tracked: tracked, live: live)
            let applyMove: (AXUIElement, CGRect) -> Bool = { element, frame in
                if shouldPreserveSizeOnRestore(scenario: scenario, tracked: tracked) {
                    return setWindowOrigin(element, origin: frame.origin)
                }
                return setWindowFrame(element, frame: frame)
            }

            if applyMove(live.element, targetFrame) {
                sleepRunLoop(0.2)
                if isAligned(scenario: scenario, tracked: tracked, element: live.element) {
                    moved += 1
                } else if applyMove(live.element, targetFrame) {
                    sleepRunLoop(0.2)
                    if isAligned(scenario: scenario, tracked: tracked, element: live.element) {
                        moved += 1
                    } else {
                        failures += 1
                    }
                } else {
                    failures += 1
                }
            } else {
                failures += 1
            }
        }

        return (
            moved: moved,
            aligned: aligned,
            failures: failures,
            unmatched: max(0, trackedWindows.count - assignments.count)
        )
    }

    func perturbOneWindowOffExpectedDisplay(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        displays: [(screen: NSScreen, id: UInt32)]
    ) -> Bool {
        let windows = liveWindows(pids: pids)
        let assignments = assignLiveWindows(trackedWindows, to: windows)
        guard let chosen = assignments.first else {
            return false
        }

        guard let targetDisplay = displays.first(where: { $0.id != chosen.0.expectedDisplayID })
        else {
            return false
        }

        let frame = perturbationFrame(for: scenario, live: chosen.1, on: targetDisplay.screen)
        let moved: Bool
        if shouldPreserveSizeOnRestore(scenario: scenario, tracked: chosen.0) {
            moved = setWindowOrigin(chosen.1.element, origin: frame.origin)
        } else {
            moved = setWindowFrame(chosen.1.element, frame: frame)
        }
        if moved {
            print(
                "Perturbed '\(chosen.0.titleHint)' to display \(targetDisplay.id) before verification."
            )
        }
        return moved
    }

    func assignLiveWindows(
        _ trackedWindows: [TrackedWindow],
        to liveWindows: [LiveWindow]
    ) -> [(TrackedWindow, LiveWindow)] {
        var available = Array(liveWindows.indices)
        var assignments: [(TrackedWindow, LiveWindow)] = []

        for tracked in trackedWindows {
            guard !available.isEmpty else {
                break
            }

            guard
                let selectedIndex = bestCandidateIndex(
                    for: tracked, windows: liveWindows, candidates: available)
            else {
                continue
            }

            assignments.append((tracked, liveWindows[selectedIndex]))
            available.removeAll { $0 == selectedIndex }
        }

        return assignments
    }

    func bestCandidateIndex(
        for tracked: TrackedWindow,
        windows: [LiveWindow],
        candidates: [Int]
    ) -> Int? {
        guard !candidates.isEmpty else {
            return nil
        }

        let appScopedCandidates: [Int]
        if let bundleID = tracked.appBundleID {
            let scoped = candidates.filter { windows[$0].appBundleID == bundleID }
            appScopedCandidates = scoped.isEmpty ? candidates : scoped
        } else {
            appScopedCandidates = candidates
        }

        let titleMatches = appScopedCandidates.filter { index in
            normalized(windows[index].title)?.contains(tracked.titleHint) == true
        }

        let pool = titleMatches.isEmpty ? appScopedCandidates : titleMatches
        let expectedFrame = tracked.expectedFrame.cgRect
        return pool.min { lhs, rhs in
            frameDistance(windows[lhs].frame, expectedFrame)
                < frameDistance(windows[rhs].frame, expectedFrame)
        }
    }

    func restoreFrame(for scenario: Scenario, tracked: TrackedWindow, live: LiveWindow) -> CGRect {
        _ = scenario
        _ = live
        return tracked.expectedFrame.cgRect
    }

    func perturbationFrame(for scenario: Scenario, live: LiveWindow, on screen: NSScreen) -> CGRect
    {
        let base = scenarioFrame(on: screen, offset: 2)
        if scenario == .finder || scenario == .freecad || scenario == .kicad {
            return CGRect(
                x: base.minX,
                y: base.minY,
                width: live.frame.width,
                height: live.frame.height
            )
        }
        return base
    }

    func shouldPreserveSizeOnRestore(scenario: Scenario, tracked: TrackedWindow) -> Bool {
        if scenario == .kicad {
            return true
        }
        guard scenario == .freecad else {
            return false
        }

        let freeCADChildPanelHints = ["tasks", "model", "report view", "python console"]
        return freeCADChildPanelHints.contains { hint in
            tracked.titleHint.contains(hint)
        }
    }

    func isAligned(scenario: Scenario, tracked: TrackedWindow, live: LiveWindow) -> Bool {
        guard let currentDisplay = displayID(for: live.frame) else {
            return false
        }
        return isAligned(
            scenario: scenario,
            tracked: tracked,
            currentDisplay: currentDisplay,
            frame: live.frame
        )
    }

    func isAligned(scenario: Scenario, tracked: TrackedWindow, element: AXUIElement) -> Bool {
        guard let frame = frameForWindow(element), let currentDisplay = displayID(for: frame) else {
            return false
        }
        return isAligned(
            scenario: scenario,
            tracked: tracked,
            currentDisplay: currentDisplay,
            frame: frame
        )
    }

    func isAligned(
        scenario: Scenario,
        tracked: TrackedWindow,
        currentDisplay: UInt32,
        frame: CGRect
    ) -> Bool {
        guard currentDisplay == tracked.expectedDisplayID else {
            return false
        }

        let expected = tracked.expectedFrame.cgRect
        let tolerance = frameTolerance(scenario: scenario)
        let positionDelta = max(abs(frame.minX - expected.minX), abs(frame.minY - expected.minY))
        let sizeDelta = max(abs(frame.width - expected.width), abs(frame.height - expected.height))
        return positionDelta <= tolerance.position && sizeDelta <= tolerance.size
    }

    func frameTolerance(scenario: Scenario) -> (position: CGFloat, size: CGFloat) {
        switch scenario {
        case .finder:
            // Finder can snap by a few points after cross-display moves.
            return (position: 8, size: 12)
        case .app, .appWorkspace:
            return (position: 4, size: 6)
        case .freecad:
            return (position: 8, size: 8)
        case .kicad:
            return (position: 8, size: 8)
        }
    }

    func frameSummary(_ frame: CGRect) -> String {
        String(
            format: "(x=%.1f y=%.1f w=%.1f h=%.1f)",
            frame.minX, frame.minY, frame.width, frame.height
        )
    }

}
