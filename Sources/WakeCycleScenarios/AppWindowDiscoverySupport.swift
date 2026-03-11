import AppKit
import ApplicationServices
import Foundation

// Design intent: keep app resolution and live-window discovery logic separate
// from scenario orchestration code paths.
extension WakeCycleScenarioRunner {
    func ensureAppsRunning(bundleIDs: [String]) throws -> [Int32] {
        try bundleIDs.map(ensureAppRunning(bundleID:))
    }

    func ensureAppRunning(bundleIDs: [String], appName: String) throws -> (
        bundleID: String, pid: Int32
    ) {
        guard let resolved = resolveRunningOrLaunchPID(bundleIDs: bundleIDs) else {
            throw RunnerError.failed("could not launch or find \(appName)")
        }
        return resolved
    }

    func ensureAppRunning(scenario: Scenario) throws -> (bundleID: String, pid: Int32) {
        try ensureAppRunning(bundleIDs: scenario.candidateBundleIDs, appName: scenario.appName)
    }

    func ensureAppRunning(bundleID: String) throws -> Int32 {
        guard let pid = waitForPID(bundleID: bundleID, timeout: 12) else {
            throw RunnerError.failed("app \(bundleID) is not running")
        }
        return pid
    }

    func resolveRunningOrLaunchPID(bundleIDs: [String]) -> (bundleID: String, pid: Int32)? {
        for bundleID in bundleIDs {
            if let app = runningApplication(bundleID: bundleID) {
                _ = runAppleScript("tell application id \"\(bundleID)\" to activate")
                return (bundleID: bundleID, pid: app.processIdentifier)
            }
        }

        for bundleID in bundleIDs {
            let didActivate = runAppleScript("tell application id \"\(bundleID)\" to activate")
            if didActivate, let pid = waitForPID(bundleID: bundleID, timeout: 12) {
                return (bundleID: bundleID, pid: pid)
            }
        }

        return nil
    }

    func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: { app in
            !app.isTerminated && app.bundleIdentifier == bundleID
        })
    }

    func waitForPID(bundleID: String, timeout: TimeInterval) -> Int32? {
        var pid: Int32?
        _ = waitUntil(timeout: timeout) {
            if let app = runningApplication(bundleID: bundleID) {
                pid = app.processIdentifier
                return true
            }
            return false
        }
        return pid
    }

    func liveWindows(pid: Int32) -> [LiveWindow] {
        let appBundleID = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.processIdentifier == pid
        })?.bundleIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let rawWindows = value as? [AXUIElement]
        else {
            return []
        }

        return rawWindows.compactMap { window in
            guard let frame = frameForWindow(window) else {
                return nil
            }
            let title = stringValue(of: window, attribute: kAXTitleAttribute as CFString)
            let role = stringValue(of: window, attribute: kAXRoleAttribute as CFString)
            let subrole = stringValue(of: window, attribute: kAXSubroleAttribute as CFString)
            return LiveWindow(
                element: window,
                appPID: pid,
                appBundleID: appBundleID,
                number: windowNumber(of: window),
                title: normalized(title),
                role: normalized(role),
                subrole: normalized(subrole),
                frame: frame
            )
        }
    }

    func liveWindows(pids: [Int32]) -> [LiveWindow] {
        pids.flatMap { liveWindows(pid: $0) }
    }

    func primarySettableWindow(pid: Int32) -> LiveWindow? {
        liveWindows(pid: pid).first(where: { isFrameSettable($0.element) })
    }

    func newWindows(current: [LiveWindow], baseline: [LiveWindow]) -> [LiveWindow] {
        let baselineNumbers = Set(baseline.compactMap(\.number))
        let baselineFrames = Set(baseline.map { frameSummary($0.frame) })
        return current.filter { window in
            !baselineNumbers.contains(window.number ?? -1)
                || !baselineFrames.contains(frameSummary(window.frame))
        }
    }

    func matchingWindows(_ windows: [LiveWindow], titleHints: [String]) -> [LiveWindow] {
        windows.filter { window in
            guard let title = window.title else {
                return false
            }
            return titleHints.contains(where: { title.contains($0) })
        }
    }

    func bestWindow(matchingTitleHint hint: String, in windows: [LiveWindow]) -> LiveWindow? {
        windows.first(where: { $0.title?.contains(hint) == true })
            ?? windows.max(by: { windowArea($0.frame) < windowArea($1.frame) })
    }
}
