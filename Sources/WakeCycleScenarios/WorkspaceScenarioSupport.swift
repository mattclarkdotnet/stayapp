import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private enum WorkspaceDirection {
    case left
    case right
}

// Design intent: keep Mission Control workspace handling isolated from the
// generic two-display scenario flow so workspace-specific assumptions stay local.
extension WakeCycleScenarioRunner {
    func prepareAppWorkspaceScenario(
        scenario: Scenario,
        displays: [ScreenDisplay],
        shouldSleep: Bool
    ) throws {
        let (_, secondaryDisplay) = try primarySecondaryDisplays(from: displays)

        _ = switchWorkspace(.left)
        sleepRunLoop(0.5)
        guard switchWorkspace(.right) else {
            throw RunnerError.failed("failed to switch to secondary workspace")
        }
        sleepRunLoop(0.5)

        let running = try ensureAppRunning(scenario: scenario)
        let pid = running.pid

        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stay-workspace-\(runID).txt")
        try "Wake-cycle workspace scenario\n".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )

        let didCreateWindow = runAppleScript(
            """
            tell application id "\(running.bundleID)"
                activate
                open POSIX file "\(escaped(fileURL.path))"
            end tell
            """)
        guard didCreateWindow else {
            throw RunnerError.scriptFailed("failed to create workspace scenario window")
        }

        let titleHint = fileURL.lastPathComponent.lowercased()
        guard
            let window = waitForVisibleTrackedWindow(
                titleHint: titleHint,
                bundleID: running.bundleID,
                pids: [pid],
                timeout: 20
            )
        else {
            throw RunnerError.failed("could not identify workspace scenario window")
        }

        let targetFrame = scenarioFrame(on: secondaryDisplay.screen, offset: 0)
        guard setWindowFrame(window.element, frame: targetFrame) else {
            throw RunnerError.failed(
                "failed to place workspace scenario window on secondary display")
        }

        guard
            waitUntil(
                timeout: 10,
                condition: {
                    guard
                        let current = self.visibleTrackedWindow(
                            titleHint: titleHint,
                            bundleID: running.bundleID,
                            pids: [pid])
                    else {
                        return false
                    }
                    return self.displayID(for: current.frame) == secondaryDisplay.id
                })
        else {
            throw RunnerError.failed(
                "workspace scenario window did not settle on secondary display")
        }

        guard
            let settled = visibleTrackedWindow(
                titleHint: titleHint, bundleID: running.bundleID, pids: [pid])
        else {
            throw RunnerError.failed("workspace scenario window disappeared before state capture")
        }

        let state = ScenarioState(
            scenario: scenario.rawValue,
            bundleID: running.bundleID,
            trackedBundleIDs: [running.bundleID],
            preparedAt: Date(),
            trackedWindows: [
                TrackedWindow(
                    appBundleID: running.bundleID,
                    titleHint: titleHint,
                    expectedDisplayID: secondaryDisplay.id,
                    expectedFrame: CodableRect(settled.frame)
                )
            ],
            createdPaths: [fileURL.path]
        )
        try persistState(state, to: stateURL(for: scenario))

        printPreparedScenarioHeader(scenario: scenario)
        print(
            "Workspace window (\(titleHint)) -> secondary workspace display \(secondaryDisplay.id)")

        performOptionalSleepAfterPrepare(shouldSleep: shouldSleep, scenario: scenario)
    }

    func verifyAppWorkspaceScenario(
        scenario: Scenario,
        checkOnly: Bool,
        timings: VerifyTimingOptions
    ) throws {
        let displays = try validatedExternalDisplays()
        let (primaryDisplay, _) = try primarySecondaryDisplays(from: displays)
        let state = try loadState(from: stateURL(for: scenario))

        guard
            scenario.candidateBundleIDs.contains(state.bundleID)
                || (state.trackedBundleIDs?.contains(where: {
                    scenario.candidateBundleIDs.contains($0)
                }) == true)
        else {
            throw RunnerError.failed(
                "state bundle mismatch: expected one of \(scenario.candidateBundleIDs), found \(state.bundleID)"
            )
        }

        guard let trackedWindow = state.trackedWindows.first else {
            throw RunnerError.failed("workspace scenario state contains no tracked windows")
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
        print("Waiting for workspace window readiness before verification.")
        guard
            waitForWorkspaceScenarioReadiness(
                trackedWindow: trackedWindow,
                pids: pids,
                timeout: timings.appWindowReadinessTimeout
            )
        else {
            throw RunnerError.failed(
                "workspace scenario window not ready for verification after wake")
        }

        if checkOnly {
            print("Check-only mode enabled; skipping perturbation and restore.")
        } else {
            guard
                let visibleWindow = visibleTrackedWindow(
                    titleHint: trackedWindow.titleHint,
                    bundleID: trackedWindow.appBundleID,
                    pids: pids)
            else {
                throw RunnerError.failed("workspace scenario window vanished before perturbation")
            }

            print("Perturbing tracked window within the secondary workspace before restore.")
            let perturbFrame = scenarioFrame(on: primaryDisplay.screen, offset: 0)
            guard setWindowFrame(visibleWindow.element, frame: perturbFrame) else {
                throw RunnerError.failed("failed to perturb workspace scenario window")
            }

            guard
                waitUntil(
                    timeout: 8,
                    condition: {
                        guard
                            let current = self.visibleTrackedWindow(
                                titleHint: trackedWindow.titleHint,
                                bundleID: trackedWindow.appBundleID,
                                pids: pids)
                        else {
                            return false
                        }
                        return self.displayID(for: current.frame) == primaryDisplay.id
                    })
            else {
                throw RunnerError.failed(
                    "workspace scenario window did not move to primary display")
            }

            print("Switching to primary workspace to hide the tracked window.")
            let hideSwitchCount = try switchWorkspaceUntilVisibilityChanges(
                direction: .left,
                expectedVisible: false,
                titleHint: trackedWindow.titleHint,
                bundleID: trackedWindow.appBundleID,
                pids: pids,
                trackedElement: visibleWindow.element,
                trackedPID: visibleWindow.appPID,
                trackedTitle: visibleWindow.title,
                maxAttempts: 3,
                failureMessage: "workspace scenario window remained visible on primary workspace"
            )

            print(
                "Tracked window is hidden on the inactive workspace; waiting to restore until that workspace is active again."
            )
            print("Switching back to secondary workspace before restore.")
            _ = try switchWorkspaceUntilVisibilityChanges(
                direction: .right,
                expectedVisible: true,
                titleHint: trackedWindow.titleHint,
                bundleID: trackedWindow.appBundleID,
                pids: pids,
                trackedElement: visibleWindow.element,
                trackedPID: visibleWindow.appPID,
                trackedTitle: visibleWindow.title,
                maxAttempts: max(1, hideSwitchCount),
                failureMessage: "workspace scenario window did not reappear on secondary workspace"
            )

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

    func waitForWorkspaceScenarioReadiness(
        trackedWindow: TrackedWindow,
        pids: [Int32],
        timeout: TimeInterval
    ) -> Bool {
        let initialTimeout = min(timeout, 15)
        if waitForVisibleTrackedWindow(
            titleHint: trackedWindow.titleHint,
            bundleID: trackedWindow.appBundleID,
            pids: pids,
            timeout: initialTimeout
        ) != nil {
            print("App/window readiness OK (matched=1/1, stable=workspace-visible).")
            return true
        }

        print(
            "Tracked workspace window not visible on the current workspace; switching right once and retrying."
        )
        guard switchWorkspace(.right) else {
            return false
        }

        let remainingTimeout = max(5, timeout - initialTimeout)
        let ready =
            waitForVisibleTrackedWindow(
                titleHint: trackedWindow.titleHint,
                bundleID: trackedWindow.appBundleID,
                pids: pids,
                timeout: remainingTimeout
            ) != nil
        if ready {
            print("App/window readiness OK (matched=1/1, stable=workspace-visible).")
        }
        return ready
    }

    func waitForVisibleTrackedWindow(
        titleHint: String,
        bundleID: String?,
        pids: [Int32],
        timeout: TimeInterval
    ) -> LiveWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date.distantPast
        while Date() < deadline {
            if let visible = visibleTrackedWindow(
                titleHint: titleHint, bundleID: bundleID, pids: pids)
            {
                return visible
            }

            if Date() >= nextLog {
                let windows = liveWindows(pids: pids).filter { window in
                    isWindowOnScreen(window.element, ownerPID: window.appPID, title: window.title)
                }
                print(
                    "Workspace visibility pending: visibleWindows=\(windows.count) titleHint='\(titleHint)'"
                )
                nextLog = Date().addingTimeInterval(1.0)
            }
            sleepRunLoop(0.2)
        }
        return visibleTrackedWindow(titleHint: titleHint, bundleID: bundleID, pids: pids)
    }

    func visibleTrackedWindow(
        titleHint: String,
        bundleID: String?,
        pids: [Int32]
    ) -> LiveWindow? {
        let tracked = TrackedWindow(
            appBundleID: bundleID,
            titleHint: titleHint,
            expectedDisplayID: 0,
            expectedFrame: CodableRect(x: 0, y: 0, width: 1, height: 1)
        )
        let visibleWindows = liveWindows(pids: pids).filter { window in
            isWindowOnScreen(window.element, ownerPID: window.appPID, title: window.title)
        }
        return bestWindowForTracked(tracked, windows: visibleWindows)
    }

    func isWindowOnScreen(
        _ window: AXUIElement,
        ownerPID: Int32? = nil,
        title: String? = nil
    ) -> Bool {
        if let number = windowNumber(of: window), onScreenWindowNumbers().contains(number) {
            return true
        }
        return isWindowVisibleWithoutWindowNumber(window, ownerPID: ownerPID, title: title)
    }

    func onScreenWindowNumbers() -> Set<Int> {
        guard
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]]
        else {
            return []
        }

        return Set(
            info.compactMap { entry in
                (entry[kCGWindowNumber as String] as? NSNumber)?.intValue
            })
    }

    func isWindowVisibleWithoutWindowNumber(
        _ window: AXUIElement,
        ownerPID: Int32?,
        title: String?
    ) -> Bool {
        guard
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]],
            let frame = frameForWindow(window)
        else {
            return false
        }

        return info.contains { entry in
            if let ownerPID {
                guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
                else {
                    return false
                }
            }

            guard let bounds = windowBounds(from: entry), frameDistance(bounds, frame) <= 24
            else {
                return false
            }

            let normalizedTitle = title?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard let normalizedTitle, !normalizedTitle.isEmpty else {
                return true
            }

            let entryTitle = (entry[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let entryTitle, !entryTitle.isEmpty else {
                return true
            }
            return entryTitle.contains(normalizedTitle) || normalizedTitle.contains(entryTitle)
        }
    }

    func windowBounds(from entry: [String: Any]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    func workspaceVisibilityDiagnostics(
        label: String,
        titleHint: String,
        bundleID: String?,
        pids: [Int32],
        trackedElement: AXUIElement,
        trackedPID: Int32,
        trackedTitle: String?
    ) -> String {
        let trackedNumber = windowNumber(of: trackedElement).map(String.init) ?? "<nil>"
        let trackedFrame = frameForWindow(trackedElement).map(frameSummary) ?? "<nil>"
        let trackedVisible = isWindowOnScreen(
            trackedElement,
            ownerPID: trackedPID,
            title: trackedTitle
        )

        let matchingWindows = liveWindows(pids: pids).filter { window in
            if let bundleID, window.appBundleID != bundleID {
                return false
            }
            return window.title?.contains(titleHint) == true
        }

        let summaries = matchingWindows.map { window in
            let visible = isWindowOnScreen(
                window.element,
                ownerPID: window.appPID,
                title: window.title
            )
            return
                "title=\(window.title ?? "<nil>") number=\(window.number.map(String.init) ?? "<nil>") visible=\(visible) frame=\(frameSummary(frameForWindow(window.element) ?? window.frame))"
        }

        let details =
            summaries.isEmpty ? "<no matching windows>" : summaries.joined(separator: "\n  ")
        return """
            Workspace diagnostics [\(label)] trackedTitle=\(trackedTitle ?? "<nil>") trackedNumber=\(trackedNumber) trackedVisible=\(trackedVisible) trackedFrame=\(trackedFrame) matches=\(matchingWindows.count)
              \(details)
            """
    }

    fileprivate func switchWorkspaceUntilVisibilityChanges(
        direction: WorkspaceDirection,
        expectedVisible: Bool,
        titleHint: String,
        bundleID: String?,
        pids: [Int32],
        trackedElement: AXUIElement,
        trackedPID: Int32,
        trackedTitle: String?,
        maxAttempts: Int,
        failureMessage: String
    ) throws -> Int {
        for attempt in 1...maxAttempts {
            guard switchWorkspace(direction) else {
                throw RunnerError.failed(
                    "failed to switch workspace \(direction == .left ? "left" : "right")")
            }

            let didReachExpectedVisibility = waitUntil(
                timeout: 8,
                condition: {
                    self.isWindowOnScreen(
                        trackedElement,
                        ownerPID: trackedPID,
                        title: trackedTitle
                    ) == expectedVisible
                }
            )
            if didReachExpectedVisibility {
                return attempt
            }
        }

        print(
            workspaceVisibilityDiagnostics(
                label: direction == .left ? "post-switch-left" : "post-switch-right",
                titleHint: titleHint,
                bundleID: bundleID,
                pids: pids,
                trackedElement: trackedElement,
                trackedPID: trackedPID,
                trackedTitle: trackedTitle
            )
        )
        throw RunnerError.failed(failureMessage)
    }

    @discardableResult
    fileprivate func switchWorkspace(_ direction: WorkspaceDirection) -> Bool {
        let keyCode = direction == .left ? 123 : 124
        let didSwitch = runAppleScript(
            """
            tell application "System Events"
                key code \(keyCode) using control down
            end tell
            """)
        guard didSwitch else {
            return false
        }
        sleepRunLoop(0.5)
        return true
    }
}
