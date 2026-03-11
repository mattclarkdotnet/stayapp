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
    private let freeCADBundleIDs = ["org.freecad.FreeCAD", "org.freecadweb.FreeCAD"]
    private let kicadMainBundleIDs = ["org.kicad.kicad", "org.kicad.kicad-nightly"]
    private let kicadPCBBundleIDs = ["org.kicad.pcbnew", "org.kicad.pcbnew-nightly"]
    private let kicadSchematicBundleIDs = ["org.kicad.eeschema", "org.kicad.eeschema-nightly"]
    private let visualPauseControlEnv = "STAY_REALAPP_VISUAL_PAUSE"

    private enum FreeCADChildPanel: String, CaseIterable {
        case tasks = "tasks"
        case model = "model"
        case reportView = "report view"
        case pythonConsole = "python console"

        var matchKeywords: [String] {
            switch self {
            case .tasks:
                return ["tasks", "task"]
            case .model:
                return ["model", "tree"]
            case .reportView:
                return ["report view", "report"]
            case .pythonConsole:
                return ["python console", "python"]
            }
        }
    }

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
            quitAppAfterScenario: true,
            createWindowsScript: """
                tell application id "com.apple.TextEdit"
                    activate
                    make new document
                    make new document
                end tell
                """
        )
    }

    @Test("Scenario 3: FreeCAD main window and child windows restore to original screens")
    func freeCADChildWindowsScenario() {
        runFreeCADChildWindowScenario()
    }

    @Test("Scenario 4: KiCad main+PCB on primary and schematic on secondary restore correctly")
    func kicadMainPcbPrimarySchematicSecondaryScenario() {
        runKiCadMainPcbPrimarySchematicSecondaryScenario()
    }

    private func runTwoWindowScenario(
        bundleID: String,
        quitAppAfterScenario: Bool = false,
        createWindowsScript: String
    ) {
        let hasAXPermission = AXIsProcessTrusted()
        #expect(hasAXPermission)
        guard hasAXPermission else {
            return
        }

        guard let displays = validatedTwoExternalDisplays() else {
            return
        }
        let screenOne = displays[0].screen
        let screenTwo = displays[1].screen
        let displayOneID = displays[0].id
        let displayTwoID = displays[1].id

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
        let cleanup: (() -> Void)? =
            quitAppAfterScenario ? { self.quitApp(bundleID: bundleID, pid: appPID) } : nil
        defer {
            cleanup?()
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

        let displayOneFrame = scenarioFrame(on: screenOne, offset: 0)
        let displayTwoFrame = scenarioFrame(on: screenTwo, offset: 0)

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
            frame: scenarioFrame(on: screenTwo, offset: 1)
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

    private func runFreeCADChildWindowScenario() {
        let hasAXPermission = AXIsProcessTrusted()
        #expect(hasAXPermission)
        guard hasAXPermission else {
            return
        }

        guard let displays = validatedTwoExternalDisplays() else {
            return
        }
        let screenOne = displays[0].screen
        let screenTwo = displays[1].screen
        let displayOneID = displays[0].id
        let displayTwoID = displays[1].id

        guard let activation = activateFirstAvailableApp(bundleIDs: freeCADBundleIDs) else {
            #expect(Bool(false))
            return
        }

        let bundleID = activation.bundleID
        let appPID = activation.pid
        defer {
            quitApp(bundleID: bundleID, pid: appPID)
        }

        let settableReady = waitUntil(timeout: 15.0) {
            self.liveSettableWindows(pid: appPID).count >= 2
        }
        #expect(settableReady)
        guard settableReady else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        guard
            let tracked = selectFreeCADScenarioWindows(pid: appPID),
            tracked.children.count == FreeCADChildPanel.allCases.count
        else {
            #expect(Bool(false))
            return
        }

        let mainWindow = tracked.main.element
        let childWindows = tracked.children.map(\.window.element)
        let trackedElements = [mainWindow] + childWindows

        let mainPlaced = moveMainWindowToScreen(
            element: mainWindow,
            screen: screenOne,
            offset: 0
        )
        #expect(mainPlaced)
        let childrenPlaced = moveChildWindowsToScreen(
            elements: childWindows,
            screen: screenTwo
        )
        #expect(childrenPlaced)
        guard mainPlaced, childrenPlaced else {
            return
        }

        let screenService = NSScreenCoordinateService()
        let baselinePlacementSettled = waitUntil(timeout: 8.0) {
            self.displayID(for: mainWindow, screenService: screenService) == displayOneID
                && childWindows.allSatisfy { window in
                    self.displayID(for: window, screenService: screenService) == displayTwoID
                }
        }
        #expect(baselinePlacementSettled)
        guard baselinePlacementSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let snapshotService = AXWindowSnapshotService(screenService: screenService)
        let appSnapshots = snapshotService.capture().filter { snapshot in
            snapshot.appPID == appPID || snapshot.appBundleID == bundleID
        }
        let baselineSnapshots = snapshotsForWindows(
            windows: trackedElements,
            appSnapshots: appSnapshots
        )
        #expect(baselineSnapshots.count == trackedElements.count)
        guard baselineSnapshots.count == trackedElements.count else {
            return
        }

        let baselineMainDisplayID = baselineSnapshots[0].screenDisplayID
        #expect(baselineMainDisplayID == displayOneID)
        for childSnapshot in baselineSnapshots.dropFirst() {
            #expect(childSnapshot.screenDisplayID == displayTwoID)
        }
        guard baselineMainDisplayID == displayOneID else {
            return
        }

        let movedMain = moveMainWindowToScreen(
            element: mainWindow,
            screen: screenTwo,
            offset: 1
        )
        #expect(movedMain)
        let movedChildren = moveChildWindowsToScreen(
            elements: childWindows,
            screen: screenOne
        )
        #expect(movedChildren)
        guard movedMain, movedChildren else {
            return
        }

        let perturbationSettled = waitUntil(timeout: 6.0) {
            self.displayID(for: mainWindow, screenService: screenService) == displayTwoID
                && childWindows.allSatisfy { window in
                    self.displayID(for: window, screenService: screenService) == displayOneID
                }
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

        let expectedDisplays = baselineSnapshots.map(\.screenDisplayID)
        #expect(expectedDisplays.allSatisfy { $0 != nil })
        guard expectedDisplays.allSatisfy({ $0 != nil }) else {
            return
        }

        let restored = waitUntil(timeout: 8.0) {
            zip(trackedElements, expectedDisplays).allSatisfy { element, expected in
                guard let expected else {
                    return false
                }
                return self.displayID(for: element, screenService: screenService) == expected
            }
        }
        #expect(restored)
        guard restored else {
            return
        }

        pauseForVisualConfirmation(duration: 2.0)
    }

    private func runKiCadMainPcbPrimarySchematicSecondaryScenario() {
        let hasAXPermission = AXIsProcessTrusted()
        #expect(hasAXPermission)
        guard hasAXPermission else {
            return
        }

        guard let displays = validatedTwoExternalDisplays() else {
            return
        }
        let primaryScreen = displays[0].screen
        let secondaryScreen = displays[1].screen
        let primaryDisplayID = displays[0].id
        let secondaryDisplayID = displays[1].id

        guard
            let kicadMain = activateFirstAvailableApp(bundleIDs: kicadMainBundleIDs),
            let pcbEditor = activateFirstAvailableApp(bundleIDs: kicadPCBBundleIDs),
            let schematicEditor = activateFirstAvailableApp(bundleIDs: kicadSchematicBundleIDs)
        else {
            #expect(Bool(false))
            return
        }
        defer {
            quitApps([
                (bundleID: schematicEditor.bundleID, pid: schematicEditor.pid),
                (bundleID: pcbEditor.bundleID, pid: pcbEditor.pid),
                (bundleID: kicadMain.bundleID, pid: kicadMain.pid),
            ])
        }

        let kicadMainReady = waitUntil(timeout: 15.0) {
            self.primarySettableWindow(pid: kicadMain.pid) != nil
        }
        let pcbEditorReady = waitUntil(timeout: 15.0) {
            self.primarySettableWindow(pid: pcbEditor.pid) != nil
        }
        let schematicEditorReady = waitUntil(timeout: 15.0) {
            self.primarySettableWindow(pid: schematicEditor.pid) != nil
        }
        #expect(kicadMainReady)
        #expect(pcbEditorReady)
        #expect(schematicEditorReady)
        guard kicadMainReady, pcbEditorReady, schematicEditorReady else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        guard
            let mainWindow = primarySettableWindow(pid: kicadMain.pid)?.element,
            let pcbWindow = primarySettableWindow(pid: pcbEditor.pid)?.element,
            let schematicWindow = primarySettableWindow(pid: schematicEditor.pid)?.element
        else {
            #expect(Bool(false))
            return
        }

        let mainPlaced = moveMainWindowToScreen(
            element: mainWindow, screen: primaryScreen, offset: 0)
        let pcbPlaced = moveMainWindowToScreen(element: pcbWindow, screen: primaryScreen, offset: 1)
        let schematicPlaced = moveMainWindowToScreen(
            element: schematicWindow,
            screen: secondaryScreen,
            offset: 0
        )
        #expect(mainPlaced)
        #expect(pcbPlaced)
        #expect(schematicPlaced)
        guard mainPlaced, pcbPlaced, schematicPlaced else {
            return
        }

        let screenService = NSScreenCoordinateService()
        let baselinePlacementSettled = waitUntil(timeout: 8.0) {
            self.displayID(for: mainWindow, screenService: screenService) == primaryDisplayID
                && self.displayID(for: pcbWindow, screenService: screenService) == primaryDisplayID
                && self.displayID(for: schematicWindow, screenService: screenService)
                    == secondaryDisplayID
        }
        #expect(baselinePlacementSettled)
        guard baselinePlacementSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let snapshotService = AXWindowSnapshotService(screenService: screenService)
        let trackedElements = [mainWindow, pcbWindow, schematicWindow]
        let trackedPIDs = Set([kicadMain.pid, pcbEditor.pid, schematicEditor.pid])
        let trackedBundleIDs = Set([
            kicadMain.bundleID, pcbEditor.bundleID, schematicEditor.bundleID,
        ])
        let appSnapshots = snapshotService.capture().filter { snapshot in
            trackedPIDs.contains(snapshot.appPID)
                || (snapshot.appBundleID.map { trackedBundleIDs.contains($0) } ?? false)
        }
        let baselineSnapshots = snapshotsForWindows(
            windows: trackedElements,
            appSnapshots: appSnapshots
        )
        #expect(baselineSnapshots.count == trackedElements.count)
        guard baselineSnapshots.count == trackedElements.count else {
            return
        }
        #expect(baselineSnapshots[0].screenDisplayID == primaryDisplayID)
        #expect(baselineSnapshots[1].screenDisplayID == primaryDisplayID)
        #expect(baselineSnapshots[2].screenDisplayID == secondaryDisplayID)

        let movedMain = moveMainWindowToScreen(
            element: mainWindow, screen: secondaryScreen, offset: 2)
        let movedPCB = moveMainWindowToScreen(
            element: pcbWindow, screen: secondaryScreen, offset: 3)
        let movedSchematic = moveMainWindowToScreen(
            element: schematicWindow,
            screen: primaryScreen,
            offset: 2
        )
        #expect(movedMain)
        #expect(movedPCB)
        #expect(movedSchematic)
        guard movedMain, movedPCB, movedSchematic else {
            return
        }

        let perturbationSettled = waitUntil(timeout: 8.0) {
            self.displayID(for: mainWindow, screenService: screenService) == secondaryDisplayID
                && self.displayID(for: pcbWindow, screenService: screenService)
                    == secondaryDisplayID
                && self.displayID(for: schematicWindow, screenService: screenService)
                    == primaryDisplayID
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

        let expectedDisplays = baselineSnapshots.map(\.screenDisplayID)
        #expect(expectedDisplays.allSatisfy { $0 != nil })
        guard expectedDisplays.allSatisfy({ $0 != nil }) else {
            return
        }

        let restored = waitUntil(timeout: 10.0) {
            zip(trackedElements, expectedDisplays).allSatisfy { element, expected in
                guard let expected else {
                    return false
                }
                return self.displayID(for: element, screenService: screenService) == expected
            }
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

    @discardableResult
    private func moveMainWindowToScreen(element: AXUIElement, screen: NSScreen, offset: Int) -> Bool
    {
        guard let frame = frameForWindow(element) else {
            return false
        }

        let visible = screen.visibleFrame
        let preferred = CGPoint(
            x: visible.minX + 40 + (CGFloat(offset) * 35),
            y: visible.minY + 60 + (CGFloat(offset) * 30)
        )
        let origin = clampedOrigin(for: frame, preferred: preferred, in: visible)
        return setWindowOrigin(element: element, origin: origin)
    }

    @discardableResult
    private func moveChildWindowsToScreen(elements: [AXUIElement], screen: NSScreen) -> Bool {
        guard !elements.isEmpty else {
            return true
        }

        let windows = elements.compactMap { element -> (element: AXUIElement, frame: CGRect)? in
            guard let frame = frameForWindow(element) else {
                return nil
            }
            return (element: element, frame: frame)
        }
        guard windows.count == elements.count else {
            return false
        }

        var group = windows[0].frame
        for window in windows.dropFirst() {
            group = group.union(window.frame)
        }

        let visible = screen.visibleFrame
        let preferredGroupOrigin = CGPoint(
            x: visible.maxX - group.width - 40,
            y: visible.minY + 40
        )
        let targetGroupOrigin = clampedRectOrigin(
            size: group.size,
            preferred: preferredGroupOrigin,
            in: visible
        )
        let delta = CGPoint(
            x: targetGroupOrigin.x - group.minX,
            y: targetGroupOrigin.y - group.minY
        )

        return windows.allSatisfy { window in
            let targetOrigin = CGPoint(
                x: window.frame.minX + delta.x,
                y: window.frame.minY + delta.y
            )
            return setWindowOrigin(element: window.element, origin: targetOrigin)
        }
    }

    private func clampedOrigin(for frame: CGRect, preferred: CGPoint, in bounds: CGRect) -> CGPoint
    {
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = max(bounds.maxX - frame.width, minX)
        let maxY = max(bounds.maxY - frame.height, minY)

        let x = min(max(preferred.x, minX), maxX)
        let y = min(max(preferred.y, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    private func clampedRectOrigin(size: CGSize, preferred: CGPoint, in bounds: CGRect) -> CGPoint {
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = max(bounds.maxX - size.width, minX)
        let maxY = max(bounds.maxY - size.height, minY)

        let x = min(max(preferred.x, minX), maxX)
        let y = min(max(preferred.y, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    private func validatedTwoExternalDisplays() -> [(screen: NSScreen, id: UInt32)]? {
        let screens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        #expect(screens.count == 2)
        guard screens.count == 2 else {
            return nil
        }

        guard
            let displayOneID = displayID(for: screens[0]),
            let displayTwoID = displayID(for: screens[1])
        else {
            #expect(Bool(false))
            return nil
        }
        #expect(CGDisplayIsBuiltin(displayOneID) == 0)
        #expect(CGDisplayIsBuiltin(displayTwoID) == 0)
        guard CGDisplayIsBuiltin(displayOneID) == 0, CGDisplayIsBuiltin(displayTwoID) == 0 else {
            return nil
        }

        let indexedDisplays: [(screen: NSScreen, id: UInt32)] = [
            (screens[0], displayOneID),
            (screens[1], displayTwoID),
        ]
        guard let primaryIndex = indexedDisplays.firstIndex(where: { CGDisplayIsMain($0.id) != 0 })
        else {
            #expect(Bool(false))
            return nil
        }
        let secondaryIndex = primaryIndex == 0 ? 1 : 0
        return [indexedDisplays[primaryIndex], indexedDisplays[secondaryIndex]]
    }

    private func activateFirstAvailableApp(bundleIDs: [String]) -> (bundleID: String, pid: Int32)? {
        for bundleID in bundleIDs {
            guard runAppleScript("tell application id \"\(bundleID)\" to activate") else {
                continue
            }
            let pidReady = waitUntil(timeout: 10.0) {
                self.runningAppPID(bundleID: bundleID) != nil
            }
            guard pidReady, let appPID = runningAppPID(bundleID: bundleID) else {
                continue
            }
            return (bundleID: bundleID, pid: appPID)
        }
        return nil
    }

    private func liveSettableWindows(pid: Int32) -> [LiveWindow] {
        liveWindows(pid: pid).filter { isFrameSettable($0.element) }
    }

    private func primarySettableWindow(pid: Int32) -> LiveWindow? {
        liveSettableWindows(pid: pid).max(by: { windowArea($0.frame) < windowArea($1.frame) })
    }

    private func selectFreeCADScenarioWindows(pid: Int32) -> (
        main: LiveWindow, children: [(panel: FreeCADChildPanel, window: LiveWindow)]
    )? {
        let settable = liveSettableWindows(pid: pid)
        guard settable.count >= 5 else {
            return nil
        }
        var remaining = settable
        var selectedChildren: [(panel: FreeCADChildPanel, window: LiveWindow)] = []
        selectedChildren.reserveCapacity(FreeCADChildPanel.allCases.count)

        for panel in FreeCADChildPanel.allCases {
            guard let bestWindow = bestFreeCADChildWindow(for: panel, in: remaining) else {
                return nil
            }
            selectedChildren.append((panel: panel, window: bestWindow))
            remaining.removeAll(where: { candidate in
                CFEqual(candidate.element, bestWindow.element)
            })
        }

        let mainWindow = chooseFreeCADMainWindow(from: remaining)
        guard let mainWindow else {
            return nil
        }

        return (main: mainWindow, children: selectedChildren)
    }

    private func chooseFreeCADMainWindow(from windows: [LiveWindow]) -> LiveWindow? {
        guard !windows.isEmpty else {
            return nil
        }

        let titledMainCandidates = windows.filter { window in
            guard let title = window.title?.lowercased() else {
                return false
            }
            return title.contains("freecad")
        }
        let pool = titledMainCandidates.isEmpty ? windows : titledMainCandidates
        return pool.max(by: { windowArea($0.frame) < windowArea($1.frame) })
    }

    private func bestFreeCADChildWindow(for panel: FreeCADChildPanel, in windows: [LiveWindow])
        -> LiveWindow?
    {
        let ranked = windows.compactMap { window -> (window: LiveWindow, score: Int)? in
            let score = freeCADChildWindowScore(window: window, panel: panel)
            guard score > 0 else {
                return nil
            }
            return (window: window, score: score)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }

            let lhsArea = windowArea(lhs.window.frame)
            let rhsArea = windowArea(rhs.window.frame)
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }

            if lhs.window.number != rhs.window.number {
                return (lhs.window.number ?? Int.max) < (rhs.window.number ?? Int.max)
            }

            if lhs.window.frame.minX != rhs.window.frame.minX {
                return lhs.window.frame.minX < rhs.window.frame.minX
            }
            return lhs.window.frame.minY < rhs.window.frame.minY
        }

        return ranked.first?.window
    }

    private func freeCADChildWindowScore(window: LiveWindow, panel: FreeCADChildPanel) -> Int {
        guard
            let title = window.title?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return 0
        }

        var score = 0
        if title == panel.rawValue {
            score += 6
        }
        for keyword in panel.matchKeywords {
            if title.contains(keyword) {
                score += 2
            }
        }
        return score
    }

    private func windowArea(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
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
        guard visualConfirmationPausesEnabled(), duration > 0 else {
            return
        }
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func visualConfirmationPausesEnabled() -> Bool {
        guard
            let raw = ProcessInfo.processInfo.environment[visualPauseControlEnv]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !raw.isEmpty
        else {
            return true
        }

        switch raw {
        case "0", "false", "no", "off":
            return false
        default:
            return true
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
                title: stringAttribute(window: window, attribute: kAXTitleAttribute as CFString),
                role: stringAttribute(window: window, attribute: kAXRoleAttribute as CFString),
                subrole: stringAttribute(
                    window: window, attribute: kAXSubroleAttribute as CFString),
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

    private func stringAttribute(window: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success else {
            return nil
        }
        return value as? String
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

    @discardableResult
    private func setWindowOrigin(element window: AXUIElement, origin: CGPoint) -> Bool {
        var mutableOrigin = origin
        guard let positionValue = AXValueCreate(.cgPoint, &mutableOrigin) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue
        )
        if positionResult == .success {
            return true
        }

        guard var currentFrame = frameForWindow(window) else {
            return false
        }
        currentFrame.origin = origin
        if let frameValue = AXValueCreate(.cgRect, &currentFrame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue)
            if frameResult == .success {
                return true
            }
        }

        return false
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

    private func quitApps(_ apps: [(bundleID: String, pid: Int32)]) {
        for app in apps {
            quitApp(bundleID: app.bundleID, pid: app.pid)
        }
    }

    private func quitApp(bundleID: String, pid: Int32) {
        _ = runAppleScript("tell application id \"\(bundleID)\" to quit")
        let quitByScript = waitUntil(timeout: 3.0) {
            self.runningApplication(pid: pid) == nil
        }
        if quitByScript {
            return
        }

        if let app = runningApplication(pid: pid) ?? runningApplication(bundleID: bundleID) {
            _ = app.terminate()
            let terminated = waitUntil(timeout: 3.0) {
                self.runningApplication(pid: pid) == nil
            }
            if terminated {
                return
            }

            _ = app.forceTerminate()
            _ = waitUntil(timeout: 2.0) {
                self.runningApplication(pid: pid) == nil
            }
        }
    }

    private func runningApplication(pid: Int32) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.processIdentifier == pid
        })
    }

    private func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleID
        })
    }

    private struct LiveWindow {
        let element: AXUIElement
        let number: Int?
        let title: String?
        let role: String?
        let subrole: String?
        let frame: CGRect
    }
}
