import ApplicationServices
import Foundation

// Design intent: keep display/app readiness waits and progress logging isolated
// from matching and restore-application logic.
extension WakeCycleScenarioRunner {
    func waitForDisplays(
        pid: Int32,
        expected: [(titleHint: String, displayID: UInt32)],
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            let windows = self.liveWindows(pid: pid)
            for expectation in expected {
                guard
                    let matched = windows.first(where: {
                        self.normalized($0.title)?.contains(expectation.titleHint) == true
                    }),
                    let currentDisplay = self.displayID(for: matched.frame),
                    currentDisplay == expectation.displayID
                else {
                    return false
                }
            }
            return true
        }
    }

    func waitForDisplayReadiness(_ requiredDisplays: Set<UInt32>, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            let online = self.onlineDisplays()
            for display in requiredDisplays {
                guard online.contains(display) else {
                    return false
                }
                if CGDisplayIsAsleep(display) != 0 {
                    return false
                }
            }
            return true
        }
    }

    func waitForDisplayReadinessWithProgress(
        _ requiredDisplays: Set<UInt32>,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date.distantPast
        while Date() < deadline {
            let online = onlineDisplays()
            let missing = requiredDisplays.filter { !online.contains($0) }.sorted()
            let asleep =
                requiredDisplays
                .filter { online.contains($0) && CGDisplayIsAsleep($0) != 0 }
                .sorted()

            if missing.isEmpty && asleep.isEmpty {
                print("Display readiness OK.")
                return true
            }

            if Date() >= nextLog {
                print("Display readiness pending: missing=\(missing) asleep=\(asleep)")
                nextLog = Date().addingTimeInterval(1.0)
            }

            sleepRunLoop(0.2)
        }

        return waitForDisplayReadiness(requiredDisplays, timeout: 0.1)
    }

    func waitForAppWindowReadinessWithProgress(
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        timeout: TimeInterval
    ) -> Bool {
        // Require repeated readiness hits to avoid starting restore during transient AX exposure.
        guard !trackedWindows.isEmpty else {
            print("App/window readiness OK (no tracked windows).")
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        let requiredStablePasses = 3
        var stablePasses = 0
        var nextLog = Date.distantPast

        while Date() < deadline {
            let windows = liveWindows(pids: pids)
            let assignments = assignLiveWindows(trackedWindows, to: windows)
            let matchedCount = assignments.count

            var expectedCountsByBundle: [String: Int] = [:]
            for tracked in trackedWindows {
                guard let bundleID = tracked.appBundleID else {
                    continue
                }
                expectedCountsByBundle[bundleID, default: 0] += 1
            }

            var liveCountsByBundle: [String: Int] = [:]
            for window in windows {
                guard let bundleID = window.appBundleID else {
                    continue
                }
                liveCountsByBundle[bundleID, default: 0] += 1
            }

            let bundleDeficits = expectedCountsByBundle.keys.sorted().compactMap {
                bundleID -> String? in
                let expected = expectedCountsByBundle[bundleID] ?? 0
                let live = liveCountsByBundle[bundleID] ?? 0
                guard live < expected else {
                    return nil
                }
                return "\(bundleID)(\(live)/\(expected))"
            }

            let ready = matchedCount == trackedWindows.count && bundleDeficits.isEmpty
            if ready {
                stablePasses += 1
                if stablePasses >= requiredStablePasses {
                    print(
                        "App/window readiness OK (matched=\(matchedCount)/\(trackedWindows.count), stable=\(stablePasses))."
                    )
                    return true
                }
            } else {
                stablePasses = 0
            }

            if Date() >= nextLog {
                var trackedTitleCounts: [String: Int] = [:]
                for tracked in trackedWindows {
                    trackedTitleCounts[tracked.titleHint, default: 0] += 1
                }
                var matchedTitleCounts: [String: Int] = [:]
                for assignment in assignments {
                    matchedTitleCounts[assignment.0.titleHint, default: 0] += 1
                }

                var unmatchedTitleHints: [String] = []
                for title in trackedTitleCounts.keys.sorted() {
                    let trackedCount = trackedTitleCounts[title] ?? 0
                    let matchedCountForTitle = matchedTitleCounts[title] ?? 0
                    let unmatchedCount = max(0, trackedCount - matchedCountForTitle)
                    if unmatchedCount > 0 {
                        unmatchedTitleHints.append(
                            contentsOf: Array(repeating: title, count: unmatchedCount))
                    }
                }
                print(
                    "App/window readiness pending: liveWindows=\(windows.count) matched=\(matchedCount)/\(trackedWindows.count) bundleDeficits=\(bundleDeficits) unmatchedTitles=\(unmatchedTitleHints)"
                )
                nextLog = Date().addingTimeInterval(1.0)
            }

            sleepRunLoop(0.2)
        }

        return false
    }

    func onlineDisplays() -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return Set(displays.prefix(Int(count)))
    }
}
