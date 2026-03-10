import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import Stay
@testable import StayCore

@Suite("RealAppScenarios")
@MainActor
struct RealAppScenarioTests {
    @Test("Scenario 1: two Finder windows restore to original screens")
    func finderTwoWindowScenario() {
        runTwoWindowScenario(
            bundleID: "com.apple.finder",
            createWindowsScript: """
                tell application id "com.apple.finder"
                    activate
                    make new Finder window to (path to home folder)
                    make new Finder window to (path to home folder)
                end tell
                """
        )
    }

    @Test("Scenario 2: two non-Finder app windows restore to original screens")
    func textEditTwoWindowScenario() {
        runTwoWindowScenario(
            bundleID: "com.apple.TextEdit",
            createWindowsScript: """
                tell application id "com.apple.TextEdit"
                    activate
                    make new document
                    make new document
                end tell
                """
        )
    }

    private func runTwoWindowScenario(bundleID: String, createWindowsScript: String) {
        let hasAXPermission = AXIsProcessTrusted()
        #expect(hasAXPermission)
        guard hasAXPermission else {
            return
        }

        let screens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        #expect(screens.count == 2)
        guard screens.count == 2 else {
            return
        }

        guard
            let displayOneID = displayID(for: screens[0]),
            let displayTwoID = displayID(for: screens[1])
        else {
            #expect(Bool(false))
            return
        }
        #expect(CGDisplayIsBuiltin(displayOneID) == 0)
        #expect(CGDisplayIsBuiltin(displayTwoID) == 0)
        guard CGDisplayIsBuiltin(displayOneID) == 0, CGDisplayIsBuiltin(displayTwoID) == 0 else {
            return
        }

        let appActivated = runAppleScript("tell application id \"\(bundleID)\" to activate")
        #expect(appActivated)
        guard appActivated else {
            return
        }

        let pidReady = waitUntil(timeout: 8.0) {
            self.runningAppPID(bundleID: bundleID) != nil
        }
        #expect(pidReady)
        guard pidReady, let appPID = runningAppPID(bundleID: bundleID) else {
            return
        }

        let existingWindows = liveWindows(pid: appPID)
        let created = runAppleScript(createWindowsScript)
        #expect(created)
        guard created else {
            return
        }

        let newWindowsReady = waitUntil(timeout: 8.0) {
            self.newlyDiscoveredWindows(pid: appPID, excluding: existingWindows).count >= 2
        }
        #expect(newWindowsReady)
        guard newWindowsReady else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let createdWindows = newlyDiscoveredWindows(pid: appPID, excluding: existingWindows)
            .filter { isFrameSettable($0.element) }
            .sorted { lhs, rhs in
                if lhs.frame.minX != rhs.frame.minX {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }
        #expect(createdWindows.count >= 2)
        guard createdWindows.count >= 2 else {
            return
        }
        let firstWindow = createdWindows[0].element
        let secondWindow = createdWindows[1].element

        defer {
            closeWindows(pid: appPID, elements: [firstWindow, secondWindow])
        }

        let displayOneFrame = scenarioFrame(on: screens[0], offset: 0)
        let displayTwoFrame = scenarioFrame(on: screens[1], offset: 0)

        let firstPlaced = setWindowFrame(element: firstWindow, frame: displayOneFrame)
        let secondPlaced = setWindowFrame(element: secondWindow, frame: displayTwoFrame)
        #expect(firstPlaced)
        #expect(secondPlaced)
        guard firstPlaced, secondPlaced else {
            return
        }

        let screenService = NSScreenCoordinateService()
        let initialPlacementSettled = waitUntil(timeout: 5.0) {
            self.displayID(for: firstWindow, screenService: screenService) == displayOneID
                && self.displayID(for: secondWindow, screenService: screenService) == displayTwoID
        }
        #expect(initialPlacementSettled)
        guard initialPlacementSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let snapshotService = AXWindowSnapshotService(screenService: screenService)
        let appSnapshots = snapshotService.capture().filter { $0.appBundleID == bundleID }
        let baselineSnapshots = snapshotsForWindows(
            windows: [firstWindow, secondWindow],
            appSnapshots: appSnapshots
        )
        #expect(baselineSnapshots.count == 2)
        guard baselineSnapshots.count == 2 else {
            return
        }

        let movedToDisplayTwo = setWindowFrame(
            element: firstWindow,
            frame: scenarioFrame(on: screens[1], offset: 1)
        )
        #expect(movedToDisplayTwo)
        guard movedToDisplayTwo else {
            return
        }

        let perturbationSettled = waitUntil(timeout: 2.0) {
            self.displayID(for: firstWindow, screenService: screenService) == displayTwoID
        }
        #expect(perturbationSettled)
        guard perturbationSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let restoreResult = snapshotService.restore(from: baselineSnapshots)
        #expect(restoreResult.recoverableFailureCount == 0)
        #expect(restoreResult.isComplete)
        guard restoreResult.recoverableFailureCount == 0 else {
            return
        }

        let expectedFirstDisplayID = baselineSnapshots[0].screenDisplayID
        let expectedSecondDisplayID = baselineSnapshots[1].screenDisplayID
        #expect(expectedFirstDisplayID != nil)
        #expect(expectedSecondDisplayID != nil)
        guard let expectedFirstDisplayID, let expectedSecondDisplayID else {
            return
        }

        let restored = waitUntil(timeout: 4.0) {
            self.displayID(for: firstWindow, screenService: screenService) == expectedFirstDisplayID
                && self.displayID(for: secondWindow, screenService: screenService)
                    == expectedSecondDisplayID
        }
        #expect(restored)
        guard restored else {
            return
        }

        pauseForVisualConfirmation(duration: 2.0)
    }

    private func scenarioFrame(on screen: NSScreen, offset: Int) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(max(420, visible.width * 0.55), visible.width - 80)
        let height = min(max(320, visible.height * 0.6), visible.height - 100)
        let x = visible.minX + 40 + (CGFloat(offset) * 35)
        let y = visible.minY + 60 + (CGFloat(offset) * 30)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func runningAppPID(bundleID: String) -> Int32? {
        NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleID
        })?.processIdentifier
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    private func waitUntil(
        timeout: TimeInterval, pollInterval: TimeInterval = 0.05, _ condition: () -> Bool
    )
        -> Bool
    {
        if condition() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
            if condition() {
                return true
            }
        }
        return condition()
    }

    private func pauseForVisualConfirmation(duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return number.uint32Value
    }

    private func displayID(for window: AXUIElement, screenService: ScreenCoordinateServicing)
        -> UInt32?
    {
        guard let frame = frameForWindow(window) else {
            return nil
        }
        return screenService.displayID(for: frame)
    }

    private func liveWindows(pid: Int32) -> [LiveWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else {
            return []
        }

        return windows.compactMap { window in
            guard let frame = frameForWindow(window) else {
                return nil
            }
            return LiveWindow(
                element: window,
                number: windowNumber(of: window),
                frame: frame
            )
        }
    }

    private func newlyDiscoveredWindows(pid: Int32, excluding baseline: [LiveWindow])
        -> [LiveWindow]
    {
        let current = liveWindows(pid: pid)
        return current.filter { window in
            !baseline.contains(where: { baselineWindow in
                CFEqual(baselineWindow.element, window.element)
            })
        }
    }

    private func windowNumber(of window: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success
        else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private func frameForWindow(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let positionRef = positionValue,
            let sizeRef = sizeValue,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let positionAX = unsafeDowncast(positionRef as AnyObject, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeRef as AnyObject, to: AXValue.self)

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &origin),
            AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    private func setWindowFrame(element window: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard
            let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue
        )
        if positionResult == .success && sizeResult == .success {
            return true
        }

        var mutableFrame = frame
        if let frameValue = AXValueCreate(.cgRect, &mutableFrame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue
            )
            if frameResult == .success {
                return true
            }
        }

        return positionResult == .success
    }

    private func isFrameSettable(_ window: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        let positionResult = AXUIElementIsAttributeSettable(
            window, kAXPositionAttribute as CFString, &positionSettable
        )
        guard positionResult == .success, positionSettable.boolValue else {
            return false
        }

        var sizeSettable = DarwinBoolean(false)
        let sizeResult = AXUIElementIsAttributeSettable(
            window, kAXSizeAttribute as CFString, &sizeSettable
        )
        return sizeResult == .success && sizeSettable.boolValue
    }

    private func snapshotsForWindows(
        windows: [AXUIElement],
        appSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        var remaining = appSnapshots
        var selected: [WindowSnapshot] = []
        selected.reserveCapacity(windows.count)

        for window in windows {
            guard let frame = frameForWindow(window), !remaining.isEmpty else {
                continue
            }

            var bestIndex = 0
            var bestDistance = frameDistance(frame, remaining[0].frame.cgRect)
            for index in remaining.indices.dropFirst() {
                let distance = frameDistance(frame, remaining[index].frame.cgRect)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            selected.append(remaining.remove(at: bestIndex))
        }
        return selected
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    private func closeWindows(pid: Int32, elements: [AXUIElement]) {
        guard !elements.isEmpty else {
            return
        }

        for _ in 0..<3 {
            let liveElements = liveWindows(pid: pid).map(\.element)
            let closableTargets = elements.filter { element in
                liveElements.contains(where: { CFEqual($0, element) })
            }
            if closableTargets.isEmpty {
                return
            }

            for window in closableTargets {
                var closeButtonValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    window, kAXCloseButtonAttribute as CFString, &closeButtonValue
                ) == .success,
                    let closeButtonRef = closeButtonValue,
                    CFGetTypeID(closeButtonRef) == AXUIElementGetTypeID()
                {
                    let closeButton = unsafeDowncast(
                        closeButtonRef as AnyObject, to: AXUIElement.self)
                    _ = AXUIElementPerformAction(
                        closeButton,
                        kAXPressAction as CFString
                    )
                }
            }

            _ = waitUntil(timeout: 1.2) {
                let current = self.liveWindows(pid: pid).map(\.element)
                return !elements.contains(where: { element in
                    current.contains(where: { CFEqual($0, element) })
                })
            }
        }
    }

    private struct LiveWindow {
        let element: AXUIElement
        let number: Int?
        let frame: CGRect
    }
}
