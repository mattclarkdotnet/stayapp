import AppKit
import ApplicationServices
import Foundation
import StayCore

// Design intent: provide a guided real-hardware awake-time display-change flow
// where the tester only performs the physical disconnect/reconnect steps and
// the runner verifies both invalidation and same-display reconnect restore.
extension WakeCycleScenarioRunner {
    func runAwakeDisplayDisconnectScenario(scenario: Scenario) throws {
        guard scenario == .finder || scenario == .app else {
            throw RunnerError.failed(
                "awake-display currently supports only 'finder' and 'app' scenarios")
        }

        try ensurePrerequisites()
        try resetScenarioAppStateIfSupported(scenario: scenario)
        let displays = try validatedExternalDisplays()
        let (primaryDisplay, secondaryDisplay) = try primarySecondaryDisplays(from: displays)
        let running = try ensureAppRunning(scenario: scenario)
        let pid = running.pid

        let baselineWindows = liveWindows(pid: pid)
        let creation = try createScenarioWindows(scenario: scenario)
        guard runAppleScript(creation.script) else {
            throw RunnerError.scriptFailed("failed to create scenario windows")
        }

        let discovered = try waitForWindows(
            pid: pid,
            timeout: 20,
            condition: { windows in
                let newWindows = self.newWindows(current: windows, baseline: baselineWindows)
                let matching = self.matchingWindows(newWindows, titleHints: creation.titleHints)
                return matching.count >= 2
            }
        )

        let newWindows = newWindows(current: discovered, baseline: baselineWindows)
        let candidates = matchingWindows(newWindows, titleHints: creation.titleHints)
        guard candidates.count >= 2 else {
            throw RunnerError.failed("could not identify both newly created windows")
        }

        let titleOne = creation.titleHints[0]
        let titleTwo = creation.titleHints[1]

        guard
            let windowOne = bestWindow(matchingTitleHint: titleOne, in: candidates),
            let windowTwo = bestWindow(matchingTitleHint: titleTwo, in: candidates)
        else {
            throw RunnerError.failed("could not match prepared windows by title hints")
        }

        let frameOne = scenarioFrame(on: primaryDisplay.screen, offset: 0)
        let frameTwo = scenarioFrame(on: secondaryDisplay.screen, offset: 0)
        guard setWindowFrame(windowOne.element, frame: frameOne) else {
            throw RunnerError.failed("failed to place first window on primary display")
        }
        guard setWindowFrame(windowTwo.element, frame: frameTwo) else {
            throw RunnerError.failed("failed to place second window on secondary display")
        }

        guard
            waitForDisplays(
                pid: pid,
                expected: [(titleOne, primaryDisplay.id), (titleTwo, secondaryDisplay.id)],
                timeout: 10
            )
        else {
            throw RunnerError.failed("prepared windows did not settle on expected displays")
        }

        let state = ScenarioState(
            scenario: scenario.rawValue,
            bundleID: running.bundleID,
            trackedBundleIDs: [running.bundleID],
            preparedAt: Date(),
            trackedWindows: [
                TrackedWindow(
                    appBundleID: running.bundleID,
                    titleHint: titleOne,
                    expectedDisplayID: primaryDisplay.id,
                    expectedFrame: CodableRect(frameOne)
                ),
                TrackedWindow(
                    appBundleID: running.bundleID,
                    titleHint: titleTwo,
                    expectedDisplayID: secondaryDisplay.id,
                    expectedFrame: CodableRect(frameTwo)
                ),
            ],
            createdPaths: creation.createdPaths
        )

        try persistState(state, to: stateURL(for: scenario))
        let startedStayProcess = try startFreshStayProcess()
        defer {
            terminateStartedStayProcess(startedStayProcess)
            terminateAllStayProcesses()
        }

        let repository = JSONSnapshotRepository(url: JSONSnapshotRepository.defaultURL())
        let capturedSnapshots = state.trackedWindows.enumerated().map { index, trackedWindow in
            WindowSnapshot(
                appPID: pid,
                appBundleID: trackedWindow.appBundleID,
                appName: scenario.appName,
                windowTitle: trackedWindow.titleHint,
                windowIndex: index,
                frame: StayCore.CodableRect(
                    x: trackedWindow.expectedFrame.x,
                    y: trackedWindow.expectedFrame.y,
                    width: trackedWindow.expectedFrame.width,
                    height: trackedWindow.expectedFrame.height
                ),
                screenDisplayID: trackedWindow.expectedDisplayID
            )
        }
        guard !capturedSnapshots.isEmpty else {
            throw RunnerError.failed("failed to derive snapshots for \(running.bundleID)")
        }
        repository.save(capturedSnapshots)

        print("Prepared awake-display scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("Snapshot file: \(JSONSnapshotRepository.defaultURL().path)")
        print("Window 1 (\(titleOne)) -> primary display \(primaryDisplay.id)")
        print("Window 2 (\(titleTwo)) -> secondary display \(secondaryDisplay.id)")
        print("")
        print("Disconnect the secondary display now.")

        let secondaryRemoved = waitUntil(timeout: 60, poll: 0.25) {
            let currentDisplayIDs = self.currentDisplayIDs()
            guard
                !currentDisplayIDs.contains(secondaryDisplay.id),
                currentDisplayIDs.count == 1
            else {
                return false
            }

            let postDisconnectSnapshots = repository.load()
            return postDisconnectSnapshots.allSatisfy { snapshot in
                snapshot.screenDisplayID != secondaryDisplay.id
            }
        }
        guard secondaryRemoved else {
            cleanupCreatedPaths(creation.createdPaths)
            throw RunnerError.failed(
                "secondary display was not disconnected within 60 seconds, or Stay did not prune its snapshots"
            )
        }

        print("PASS: disconnected secondary display snapshots were invalidated by Stay.")
        print("")
        print("Reconnect the same secondary display now so cleanup can finish.")

        let secondaryRestored = waitUntil(timeout: 60, poll: 0.25) {
            let currentDisplayIDs = self.currentDisplayIDs()
            return currentDisplayIDs.contains(secondaryDisplay.id) && currentDisplayIDs.count == 2
        }
        guard secondaryRestored else {
            cleanupCreatedPaths(creation.createdPaths)
            throw RunnerError.failed("secondary display was not reconnected within 60 seconds")
        }

        let verificationPassed = waitForVerificationWithProgress(
            scenario: scenario,
            trackedWindows: state.trackedWindows,
            pids: [pid],
            timeout: 20
        )
        guard verificationPassed else {
            cleanupCreatedPaths(creation.createdPaths)
            throw RunnerError.failed(
                "tracked windows did not return to their expected displays after the reconnect"
            )
        }

        cleanupCreatedPaths(creation.createdPaths)
        print("PASS: windows returned to their expected displays after reconnect.")
    }

    func currentDisplayIDs() -> Set<UInt32> {
        Set(NSScreen.screens.compactMap(displayID(for:)))
    }
}
