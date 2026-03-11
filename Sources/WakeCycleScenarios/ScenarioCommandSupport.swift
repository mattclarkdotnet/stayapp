import ApplicationServices
import Foundation

// Design intent: isolate prepare/verify command behavior from cycle control and
// low-level helper modules.
extension WakeCycleScenarioRunner {
    func prepare(scenario: Scenario, shouldSleep: Bool) throws {
        try ensurePrerequisites()
        let displays = try validatedExternalDisplays()

        if scenario == .kicad {
            try prepareKiCadScenario(
                scenario: scenario,
                displays: displays,
                shouldSleep: shouldSleep
            )
            return
        }

        let running = try ensureAppRunning(scenario: scenario)
        let pid = running.pid

        if scenario == .freecad {
            try prepareFreeCADScenario(
                scenario: scenario,
                activeBundleID: running.bundleID,
                pid: pid,
                displays: displays,
                shouldSleep: shouldSleep
            )
            return
        }

        let display1 = displays[0]
        let display2 = displays[1]
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
            throw RunnerError.failed("could not match windows by title hints")
        }

        let frameOne = scenarioFrame(on: display1.screen, offset: 0)
        let frameTwo = scenarioFrame(on: display2.screen, offset: 0)

        guard setWindowFrame(windowOne.element, frame: frameOne) else {
            throw RunnerError.failed("failed to place first window")
        }
        guard setWindowFrame(windowTwo.element, frame: frameTwo) else {
            throw RunnerError.failed("failed to place second window")
        }

        guard
            waitForDisplays(
                pid: pid, expected: [(titleOne, display1.id), (titleTwo, display2.id)], timeout: 10)
        else {
            throw RunnerError.failed("windows did not settle on target displays")
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
                    expectedDisplayID: display1.id,
                    expectedFrame: CodableRect(frameOne)
                ),
                TrackedWindow(
                    appBundleID: running.bundleID,
                    titleHint: titleTwo,
                    expectedDisplayID: display2.id,
                    expectedFrame: CodableRect(frameTwo)
                ),
            ],
            createdPaths: creation.createdPaths
        )

        try persistState(state, to: stateURL(for: scenario))

        printPreparedScenarioHeader(scenario: scenario)
        print("Window 1 (\(titleOne)) -> display \(display1.id)")
        print("Window 2 (\(titleTwo)) -> display \(display2.id)")

        performOptionalSleepAfterPrepare(shouldSleep: shouldSleep, scenario: scenario)
    }

    func prepareFreeCADScenario(
        scenario: Scenario,
        activeBundleID: String,
        pid: Int32,
        displays: [ScreenDisplay],
        shouldSleep: Bool
    ) throws {
        let (primaryDisplay, secondaryDisplay) = try primarySecondaryDisplays(from: displays)
        let windowsReady = waitUntil(timeout: 20) {
            self.liveWindows(pid: pid).count >= 5
        }
        guard windowsReady else {
            throw RunnerError.failed(
                "timed out waiting for FreeCAD windows (expected main + tasks/model/report/python)")
        }

        guard
            let tracked = selectFreeCADScenarioWindows(pid: pid),
            tracked.children.count == FreeCADChildPanel.allCases.count
        else {
            throw RunnerError.failed(
                "could not identify FreeCAD main window and child windows (tasks/model/report view/python console)"
            )
        }

        let mainWindow = tracked.main.element
        let childWindows = tracked.children.map(\.window.element)
        let mainPlaced = moveMainWindowToScreen(
            element: mainWindow,
            screen: primaryDisplay.screen,
            offset: 0
        )
        guard mainPlaced else {
            throw RunnerError.failed("failed to place FreeCAD main window on primary display")
        }

        let childrenPlaced = moveChildWindowsToScreen(
            elements: childWindows, screen: secondaryDisplay.screen)
        guard childrenPlaced else {
            throw RunnerError.failed("failed to place FreeCAD child windows on secondary display")
        }

        let settled = waitUntil(timeout: 10) {
            guard
                let mainFrame = self.frameForWindow(mainWindow),
                self.displayID(for: mainFrame) == primaryDisplay.id
            else {
                return false
            }
            return childWindows.allSatisfy { window in
                guard let frame = self.frameForWindow(window) else {
                    return false
                }
                return self.displayID(for: frame) == secondaryDisplay.id
            }
        }
        guard settled else {
            throw RunnerError.failed("FreeCAD windows did not settle on expected displays")
        }

        var trackedWindows: [TrackedWindow] = []
        trackedWindows.reserveCapacity(1 + tracked.children.count)

        guard let mainFrame = frameForWindow(mainWindow) else {
            throw RunnerError.failed("could not read FreeCAD main window frame after placement")
        }
        let mainTitleHint = normalized(tracked.main.title) ?? "freecad"
        trackedWindows.append(
            TrackedWindow(
                appBundleID: activeBundleID,
                titleHint: mainTitleHint,
                expectedDisplayID: primaryDisplay.id,
                expectedFrame: CodableRect(mainFrame)
            )
        )

        for child in tracked.children {
            guard let frame = frameForWindow(child.window.element) else {
                throw RunnerError.failed(
                    "could not read FreeCAD child window frame after placement")
            }
            trackedWindows.append(
                TrackedWindow(
                    appBundleID: activeBundleID,
                    titleHint: child.panel.rawValue,
                    expectedDisplayID: secondaryDisplay.id,
                    expectedFrame: CodableRect(frame)
                )
            )
        }

        let state = ScenarioState(
            scenario: scenario.rawValue,
            bundleID: activeBundleID,
            trackedBundleIDs: [activeBundleID],
            preparedAt: Date(),
            trackedWindows: trackedWindows,
            createdPaths: []
        )
        try persistState(state, to: stateURL(for: scenario))

        printPreparedScenarioHeader(scenario: scenario)
        print("Main window (\(mainTitleHint)) -> primary display \(primaryDisplay.id)")
        for child in tracked.children {
            print(
                "Child window (\(child.panel.rawValue)) -> secondary display \(secondaryDisplay.id)"
            )
        }

        performOptionalSleepAfterPrepare(shouldSleep: shouldSleep, scenario: scenario)
    }

    func prepareKiCadScenario(
        scenario: Scenario,
        displays: [ScreenDisplay],
        shouldSleep: Bool
    ) throws {
        let (primaryDisplay, secondaryDisplay) = try primarySecondaryDisplays(from: displays)
        let main = try ensureAppRunning(
            bundleIDs: scenario.candidateBundleIDs, appName: "KiCad main")
        let pcb = try ensureAppRunning(bundleIDs: kicadPCBBundleIDs, appName: "KiCad PCB editor")
        let schematic = try ensureAppRunning(
            bundleIDs: kicadSchematicBundleIDs,
            appName: "KiCad schematic editor"
        )

        let ready = waitUntil(timeout: 20) {
            self.primarySettableWindow(pid: main.pid) != nil
                && self.primarySettableWindow(pid: pcb.pid) != nil
                && self.primarySettableWindow(pid: schematic.pid) != nil
        }
        guard ready else {
            throw RunnerError.failed("timed out waiting for KiCad main/PCB/schematic windows")
        }

        guard
            let mainWindow = primarySettableWindow(pid: main.pid)?.element,
            let pcbWindow = primarySettableWindow(pid: pcb.pid)?.element,
            let schematicWindow = primarySettableWindow(pid: schematic.pid)?.element
        else {
            throw RunnerError.failed("could not identify KiCad main/PCB/schematic windows")
        }

        let mainPlaced = moveMainWindowToScreen(
            element: mainWindow,
            screen: primaryDisplay.screen,
            offset: 0
        )
        let pcbPlaced = moveMainWindowToScreen(
            element: pcbWindow,
            screen: primaryDisplay.screen,
            offset: 1
        )
        let schematicPlaced = moveMainWindowToScreen(
            element: schematicWindow,
            screen: secondaryDisplay.screen,
            offset: 0
        )
        guard mainPlaced, pcbPlaced, schematicPlaced else {
            throw RunnerError.failed("failed to place KiCad windows on target displays")
        }

        let settled = waitUntil(timeout: 10) {
            guard
                let mainFrame = self.frameForWindow(mainWindow),
                let pcbFrame = self.frameForWindow(pcbWindow),
                let schematicFrame = self.frameForWindow(schematicWindow)
            else {
                return false
            }
            return self.displayID(for: mainFrame) == primaryDisplay.id
                && self.displayID(for: pcbFrame) == primaryDisplay.id
                && self.displayID(for: schematicFrame) == secondaryDisplay.id
        }
        guard settled else {
            throw RunnerError.failed("KiCad windows did not settle on expected displays")
        }

        guard
            let mainFrame = frameForWindow(mainWindow),
            let pcbFrame = frameForWindow(pcbWindow),
            let schematicFrame = frameForWindow(schematicWindow)
        else {
            throw RunnerError.failed("could not read KiCad window frames after placement")
        }

        let mainTitleHint =
            normalized(stringValue(of: mainWindow, attribute: kAXTitleAttribute as CFString))
            ?? "kicad main"
        let pcbTitleHint =
            normalized(stringValue(of: pcbWindow, attribute: kAXTitleAttribute as CFString))
            ?? "pcb editor"
        let schematicTitleHint =
            normalized(
                stringValue(of: schematicWindow, attribute: kAXTitleAttribute as CFString)
            ) ?? "schematic editor"

        let state = ScenarioState(
            scenario: scenario.rawValue,
            bundleID: main.bundleID,
            trackedBundleIDs: [main.bundleID, pcb.bundleID, schematic.bundleID],
            preparedAt: Date(),
            trackedWindows: [
                TrackedWindow(
                    appBundleID: main.bundleID,
                    titleHint: mainTitleHint,
                    expectedDisplayID: primaryDisplay.id,
                    expectedFrame: CodableRect(mainFrame)
                ),
                TrackedWindow(
                    appBundleID: pcb.bundleID,
                    titleHint: pcbTitleHint,
                    expectedDisplayID: primaryDisplay.id,
                    expectedFrame: CodableRect(pcbFrame)
                ),
                TrackedWindow(
                    appBundleID: schematic.bundleID,
                    titleHint: schematicTitleHint,
                    expectedDisplayID: secondaryDisplay.id,
                    expectedFrame: CodableRect(schematicFrame)
                ),
            ],
            createdPaths: []
        )
        try persistState(state, to: stateURL(for: scenario))

        printPreparedScenarioHeader(scenario: scenario)
        print("Main window (\(mainTitleHint)) -> primary display \(primaryDisplay.id)")
        print("PCB window (\(pcbTitleHint)) -> primary display \(primaryDisplay.id)")
        print(
            "Schematic window (\(schematicTitleHint)) -> secondary display \(secondaryDisplay.id)")

        performOptionalSleepAfterPrepare(shouldSleep: shouldSleep, scenario: scenario)
    }

    func verify(
        scenario: Scenario,
        checkOnly: Bool,
        timings: VerifyTimingOptions,
        skipPrerequisiteCheck: Bool
    ) throws {
        if skipPrerequisiteCheck {
            try fileManager.createDirectory(
                at: scenarioDirectory, withIntermediateDirectories: true)
        } else {
            try ensurePrerequisites()
        }
        let displays = try validatedExternalDisplays()
        let state = try loadState(from: stateURL(for: scenario))

        guard
            scenario.candidateBundleIDs.contains(state.bundleID)
                || (state.trackedBundleIDs?.contains(where: {
                    scenario.candidateBundleIDs.contains($0)
                })
                    == true)
        else {
            throw RunnerError.failed(
                "state bundle mismatch: expected one of \(scenario.candidateBundleIDs), found \(state.bundleID)"
            )
        }

        let requiredDisplays = Set(state.trackedWindows.map(\.expectedDisplayID))
        print("Waiting for displays to be online/awake: \(requiredDisplays.sorted())")
        guard
            waitForDisplayReadinessWithProgress(
                requiredDisplays, timeout: timings.displayReadinessTimeout)
        else {
            throw RunnerError.failed("required displays not ready after wake")
        }

        let bundleIDs = state.trackedBundleIDs ?? [state.bundleID]
        let pids = try ensureAppsRunning(bundleIDs: bundleIDs)
        print("Verifying scenario '\(scenario.rawValue)' for app pid(s)=\(pids)")
        print("Waiting for app/window readiness before verification.")
        guard
            waitForAppWindowReadinessWithProgress(
                trackedWindows: state.trackedWindows,
                pids: pids,
                timeout: timings.appWindowReadinessTimeout
            )
        else {
            throw RunnerError.failed("app windows not ready for verification after wake")
        }

        if checkOnly {
            print("Check-only mode enabled; skipping perturbation and restore.")
        } else {
            print("Perturbing one tracked window before restore.")
            let didPerturb = perturbOneWindowOffExpectedDisplay(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pids: pids,
                displays: displays
            )
            if didPerturb {
                sleepRunLoop(1.0)
            } else {
                print("No perturbation was applied; continuing to restore anyway.")
            }

            print("Applying restore attempts from saved scenario state.")
            _ = restoreTrackedWindowsWithProgress(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pids: pids,
                timeout: timings.restoreTimeout
            )
        }

        let passed = waitForVerificationWithProgress(
            scenario: scenario,
            trackedWindows: state.trackedWindows,
            pids: pids,
            timeout: timings.verificationTimeout
        )

        let details: [String]
        if passed {
            details = ["all tracked windows restored to expected displays"]
        } else {
            details = verificationMismatches(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pids: pids
            )
        }

        let report = ScenarioReport(
            scenario: scenario.rawValue,
            verifiedAt: Date(),
            passed: passed,
            details: details
        )
        try persistReport(report, to: reportURL(for: scenario))

        if passed {
            print("PASS: wake-cycle scenario '\(scenario.rawValue)'")
        } else {
            print("FAIL: wake-cycle scenario '\(scenario.rawValue)'")
            details.forEach { print("  - \($0)") }
            throw RunnerError.failed("verification failed")
        }

        cleanupCreatedPaths(state.createdPaths)
        print("Report file: \(reportURL(for: scenario).path)")
    }

    func performOptionalSleepAfterPrepare(shouldSleep: Bool, scenario: Scenario) {
        guard shouldSleep else {
            print("Skipped sleep (--no-sleep). Manually sleep/wake, then run verify.")
            return
        }
        print("Sleeping machine in 3 seconds. After wake/login, run:")
        print("  swift run WakeCycleScenarios verify \(scenario.rawValue)")
        Thread.sleep(forTimeInterval: 3)
        _ = runCommand("/usr/bin/pmset", ["sleepnow"])
    }

    func printPreparedScenarioHeader(scenario: Scenario) {
        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("State file: \(stateURL(for: scenario).path)")
    }
}
