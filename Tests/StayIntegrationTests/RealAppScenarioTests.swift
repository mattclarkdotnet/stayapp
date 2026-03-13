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
        runWithCleanStayEnvironment {
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
    }

    @Test("Scenario 2: two non-Finder app windows restore to original screens")
    func textEditTwoWindowScenario() {
        runWithCleanStayEnvironment {
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
    }

    @Test("Scenario 3: FreeCAD main window and child windows restore to original screens")
    func freeCADChildWindowsScenario() {
        runWithCleanStayEnvironment {
            runFreeCADChildWindowScenario()
        }
    }

    @Test("Scenario 4: KiCad main+PCB on primary and schematic on secondary restore correctly")
    func kicadMainPcbPrimarySchematicSecondaryScenario() {
        runWithCleanStayEnvironment {
            runKiCadMainPcbPrimarySchematicSecondaryScenario()
        }
    }

    @Test(
        "Scenario 5: TextEdit window on secondary workspace restores when that workspace becomes active"
    )
    func textEditSecondaryWorkspaceScenario() {
        runWithCleanStayEnvironment {
            runTextEditSecondaryWorkspaceScenario()
        }
    }

    @Test("Scenario 6: full-screen app is ignored during capture/restore")
    func fullScreenAppIsIgnoredScenario() {
        runWithCleanStayEnvironment {
            runFullScreenAppIgnoredScenario()
        }
    }

    private func runWithCleanStayEnvironment(_ body: () -> Void) {
        terminateAllStayProcesses()
        defer {
            terminateAllStayProcesses()
        }
        body()
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
        resetScriptedScenarioAppState(bundleIDs: [bundleID])
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

    private func runTextEditSecondaryWorkspaceScenario() {
        let hasAXPermission = AXIsProcessTrusted()
        #expect(hasAXPermission)
        guard hasAXPermission else {
            return
        }

        guard let displays = validatedTwoExternalDisplays() else {
            return
        }
        let textEditBundleID = "com.apple.TextEdit"
        resetScriptedScenarioAppState(bundleIDs: [textEditBundleID])
        let primaryScreen = displays[0].screen
        let secondaryScreen = displays[1].screen
        let primaryDisplayID = displays[0].id
        let secondaryDisplayID = displays[1].id

        _ = switchWorkspace(.left)
        pauseForVisualConfirmation(duration: 0.5)

        let switchedToSecondaryWorkspace = switchWorkspace(.right)
        #expect(switchedToSecondaryWorkspace)
        guard switchedToSecondaryWorkspace else {
            return
        }
        pauseForVisualConfirmation(duration: 0.5)

        let appActivated = runAppleScript("tell application id \"\(textEditBundleID)\" to activate")
        #expect(appActivated)
        guard appActivated else {
            return
        }

        let pidReady = waitUntil(timeout: 8.0) {
            self.runningAppPID(bundleID: textEditBundleID) != nil
        }
        #expect(pidReady)
        guard pidReady, let appPID = runningAppPID(bundleID: textEditBundleID) else {
            return
        }

        let existingWindows = liveWindows(pid: appPID)
        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stay-workspace-\(runID).txt")
        try? "Workspace scenario\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let createWindow = runAppleScript(
            """
            tell application id "\(textEditBundleID)"
                activate
                open POSIX file "\(escapedAppleScriptString(fileURL.path))"
            end tell
            """)
        #expect(createWindow)
        guard createWindow else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let windowReady = waitUntil(timeout: 8.0) {
            self.newlyDiscoveredWindows(pid: appPID, excluding: existingWindows).contains(where: {
                ($0.title ?? "").lowercased().contains(fileURL.lastPathComponent.lowercased())
            })
        }
        #expect(windowReady)
        guard windowReady else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let createdWindows = newlyDiscoveredWindows(pid: appPID, excluding: existingWindows)
        let matchingWindow = createdWindows.first(where: {
            ($0.title ?? "").lowercased().contains(fileURL.lastPathComponent.lowercased())
        })
        #expect(matchingWindow != nil)
        guard let matchingWindow else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let window = matchingWindow.element

        defer {
            closeWindows(pid: appPID, elements: [window])
            quitApp(bundleID: textEditBundleID, pid: appPID)
            try? FileManager.default.removeItem(at: fileURL)
            _ = switchWorkspace(.left)
        }

        let secondaryPlaced = setWindowFrame(
            element: window,
            frame: scenarioFrame(on: secondaryScreen, offset: 0)
        )
        #expect(secondaryPlaced)
        guard secondaryPlaced else {
            return
        }

        let screenService = NSScreenCoordinateService()
        let baselinePlacementSettled = waitUntil(timeout: 5.0) {
            self.displayID(for: window, screenService: screenService) == secondaryDisplayID
                && self.isWindowOnScreen(window, ownerPID: appPID)
        }
        #expect(baselinePlacementSettled)
        guard baselinePlacementSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let snapshotService = AXWindowSnapshotService(screenService: screenService)
        let appSnapshots = snapshotService.capture().filter { $0.appBundleID == textEditBundleID }
        let baselineSnapshots = snapshotsForWindows(windows: [window], appSnapshots: appSnapshots)
        #expect(baselineSnapshots.count == 1)
        #expect(baselineSnapshots.first?.screenDisplayID == secondaryDisplayID)
        guard baselineSnapshots.count == 1,
            baselineSnapshots.first?.screenDisplayID == secondaryDisplayID
        else {
            return
        }

        let primaryPlaced = setWindowFrame(
            element: window,
            frame: scenarioFrame(on: primaryScreen, offset: 0)
        )
        #expect(primaryPlaced)
        guard primaryPlaced else {
            return
        }

        let perturbationSettled = waitUntil(timeout: 5.0) {
            self.displayID(for: window, screenService: screenService) == primaryDisplayID
                && self.isWindowOnScreen(window, ownerPID: appPID)
        }
        #expect(perturbationSettled)
        guard perturbationSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let switchedBackToPrimaryWorkspace = switchWorkspace(.left)
        #expect(switchedBackToPrimaryWorkspace)
        guard switchedBackToPrimaryWorkspace else {
            return
        }

        let hiddenOnPrimaryWorkspace = waitUntil(timeout: 5.0) {
            !self.isWindowOnScreen(window, ownerPID: appPID)
        }
        #expect(hiddenOnPrimaryWorkspace)
        guard hiddenOnPrimaryWorkspace else {
            return
        }
        pauseForVisualConfirmation(duration: 0.5)

        let repository = InMemorySnapshotRepository()
        let scheduler = ManualScheduler()
        let coordinator = SleepWakeCoordinator(
            capturing: snapshotService,
            restoring: snapshotService,
            repository: repository,
            readinessChecker: ImmediateRestoreReadinessChecker(),
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.25,
            maxWaitAfterWake: 10
        )
        coordinator.handleRestoreRequested(with: baselineSnapshots)
        scheduler.runNext()

        let remainedDeferred = waitUntil(timeout: 2.0) {
            !self.isWindowOnScreen(window, ownerPID: appPID)
        }
        #expect(remainedDeferred)
        guard remainedDeferred else {
            return
        }

        let switchedAgainToSecondaryWorkspace = switchWorkspace(.right)
        #expect(switchedAgainToSecondaryWorkspace)
        guard switchedAgainToSecondaryWorkspace else {
            return
        }

        let exposedAgainOnSecondaryWorkspace = waitUntil(timeout: 3.0) {
            self.isWindowOnScreen(window, ownerPID: appPID)
        }
        #expect(exposedAgainOnSecondaryWorkspace)
        guard exposedAgainOnSecondaryWorkspace else {
            return
        }

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        scheduler.runNext()
        let restoredOnSecondaryWorkspace = waitUntil(timeout: 6.0) {
            self.isWindowOnScreen(window, ownerPID: appPID)
                && self.displayID(for: window, screenService: screenService) == secondaryDisplayID
        }
        #expect(restoredOnSecondaryWorkspace)
        guard restoredOnSecondaryWorkspace else {
            return
        }

        pauseForVisualConfirmation(duration: 2.0)
    }

    private func runFullScreenAppIgnoredScenario() {
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
        let finderBundleID = "com.apple.finder"
        let textEditBundleID = "com.apple.TextEdit"

        resetScriptedScenarioAppState(bundleIDs: [finderBundleID, textEditBundleID])

        let textEditActivated = runAppleScript(
            "tell application id \"\(textEditBundleID)\" to activate")
        #expect(textEditActivated)
        guard textEditActivated else {
            return
        }

        let textEditReady = waitUntil(timeout: 8.0) {
            self.runningAppPID(bundleID: textEditBundleID) != nil
        }
        #expect(textEditReady)
        guard textEditReady, let textEditPID = runningAppPID(bundleID: textEditBundleID) else {
            return
        }

        let existingTextEditWindows = liveWindows(pid: textEditPID)
        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stay-fullscreen-\(runID).txt")
        try? "Full-screen ignore scenario\n".write(to: fileURL, atomically: true, encoding: .utf8)

        defer {
            quitApp(bundleID: textEditBundleID, pid: textEditPID)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let createTextEditWindow = runAppleScript(
            """
            tell application id "\(textEditBundleID)"
                activate
                open POSIX file "\(escapedAppleScriptString(fileURL.path))"
            end tell
            """
        )
        #expect(createTextEditWindow)
        guard createTextEditWindow else {
            return
        }

        let titleHint = fileURL.lastPathComponent.lowercased()
        let textEditWindowReady = waitUntil(timeout: 8.0) {
            self.newlyDiscoveredWindows(pid: textEditPID, excluding: existingTextEditWindows)
                .contains(where: { ($0.title ?? "").lowercased().contains(titleHint) })
        }
        #expect(textEditWindowReady)
        guard textEditWindowReady,
            let textEditWindow = findWindow(pid: textEditPID, titleHint: titleHint)
        else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let secondaryPlaced = setWindowFrame(
            element: textEditWindow.element,
            frame: scenarioFrame(on: secondaryScreen, offset: 0)
        )
        #expect(secondaryPlaced)
        guard secondaryPlaced else {
            return
        }

        let screenService = NSScreenCoordinateService()
        let placementSettled = waitUntil(timeout: 5.0) {
            self.findWindow(pid: textEditPID, titleHint: titleHint).map {
                self.displayID(for: $0.element, screenService: screenService)
            } == secondaryDisplayID
        }
        #expect(placementSettled)
        guard placementSettled,
            let preparedFullScreenWindow = findWindow(pid: textEditPID, titleHint: titleHint)
        else {
            return
        }

        let enteredFullScreen = setWindowFullScreen(
            preparedFullScreenWindow.element,
            bundleID: textEditBundleID,
            fullScreen: true
        )
        #expect(enteredFullScreen)
        guard enteredFullScreen else {
            return
        }

        let fullScreenSettled = waitUntil(timeout: 12.0) {
            self.findWindow(pid: textEditPID, titleHint: titleHint).map {
                self.isWindowFullScreen($0.element)
            } == true
        }
        #expect(fullScreenSettled)
        guard fullScreenSettled else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let finderActivated = runAppleScript(
            "tell application id \"\(finderBundleID)\" to activate")
        #expect(finderActivated)
        guard finderActivated else {
            return
        }

        let finderReady = waitUntil(timeout: 8.0) {
            self.runningAppPID(bundleID: finderBundleID) != nil
        }
        #expect(finderReady)
        guard finderReady, let finderPID = runningAppPID(bundleID: finderBundleID) else {
            return
        }

        let existingFinderWindows = liveWindows(pid: finderPID)
        let createFinderWindows = runAppleScript(
            """
            tell application id "\(finderBundleID)"
                activate
                make new Finder window to (path to home folder)
                make new Finder window to (path to home folder)
            end tell
            """
        )
        #expect(createFinderWindows)
        guard createFinderWindows else {
            return
        }

        let finderWindowsReady = waitUntil(timeout: 8.0) {
            self.newlyDiscoveredWindows(pid: finderPID, excluding: existingFinderWindows).count >= 2
        }
        #expect(finderWindowsReady)
        guard finderWindowsReady else {
            return
        }
        pauseForVisualConfirmation(duration: 1.0)

        let createdFinderWindows = newlyDiscoveredWindows(
            pid: finderPID, excluding: existingFinderWindows
        )
        .filter { isFrameSettable($0.element) }
        .sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }
        #expect(createdFinderWindows.count >= 2)
        guard createdFinderWindows.count >= 2 else {
            return
        }

        let finderWindowOne = createdFinderWindows[0].element
        let finderWindowTwo = createdFinderWindows[1].element
        defer {
            closeWindows(pid: finderPID, elements: [finderWindowOne, finderWindowTwo])
        }

        let finderWindowOnePlaced = setWindowFrame(
            element: finderWindowOne,
            frame: scenarioFrame(on: primaryScreen, offset: 0)
        )
        let finderWindowTwoPlaced = setWindowFrame(
            element: finderWindowTwo,
            frame: scenarioFrame(on: secondaryScreen, offset: 0)
        )
        #expect(finderWindowOnePlaced)
        #expect(finderWindowTwoPlaced)
        guard finderWindowOnePlaced, finderWindowTwoPlaced else {
            return
        }

        let finderPlacementSettled = waitUntil(timeout: 5.0) {
            self.displayID(for: finderWindowOne, screenService: screenService) == primaryDisplayID
                && self.displayID(for: finderWindowTwo, screenService: screenService)
                    == secondaryDisplayID
        }
        #expect(finderPlacementSettled)
        guard finderPlacementSettled else {
            return
        }

        let snapshotService = AXWindowSnapshotService(screenService: screenService)
        let snapshots = snapshotService.capture()
        let finderSnapshots = snapshotsForWindows(
            windows: [finderWindowOne, finderWindowTwo],
            appSnapshots: snapshots.filter { $0.appBundleID == finderBundleID }
        )
        let fullScreenSnapshots = snapshots.filter { $0.appBundleID == textEditBundleID }
        #expect(finderSnapshots.count == 2)
        #expect(fullScreenSnapshots.isEmpty)
        guard finderSnapshots.count == 2, fullScreenSnapshots.isEmpty else {
            return
        }

        let movedFinderWindow = setWindowFrame(
            element: finderWindowOne,
            frame: scenarioFrame(on: secondaryScreen, offset: 1)
        )
        #expect(movedFinderWindow)
        guard movedFinderWindow else {
            return
        }

        let finderPerturbationSettled = waitUntil(timeout: 5.0) {
            self.displayID(for: finderWindowOne, screenService: screenService) == secondaryDisplayID
        }
        #expect(finderPerturbationSettled)
        guard finderPerturbationSettled else {
            return
        }

        let restoreResult = snapshotService.restore(from: finderSnapshots)
        #expect(restoreResult.recoverableFailureCount == 0)
        #expect(restoreResult.isComplete)
        guard restoreResult.recoverableFailureCount == 0 else {
            return
        }

        let finderRestored = waitUntil(timeout: 8.0) {
            self.displayID(for: finderWindowOne, screenService: screenService) == primaryDisplayID
                && self.displayID(for: finderWindowTwo, screenService: screenService)
                    == secondaryDisplayID
        }
        #expect(finderRestored)

        let textEditStillRunning = runningApplication(pid: textEditPID) != nil
        #expect(textEditStillRunning)

        let postRestoreFullScreenSnapshots = snapshotService.capture().filter {
            $0.appBundleID == textEditBundleID
        }
        #expect(postRestoreFullScreenSnapshots.isEmpty)

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

        guard let scenarioActivation = activateFreeCADScenarioApp(maxAttempts: 2) else {
            #expect(Bool(false))
            return
        }

        let bundleID = scenarioActivation.bundleID
        let appPID = scenarioActivation.pid
        let tracked = scenarioActivation.tracked
        defer {
            quitApp(bundleID: bundleID, pid: appPID)
        }

        pauseForVisualConfirmation(duration: 1.0)

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

    private func activateFreeCADScenarioApp(maxAttempts: Int) -> (
        bundleID: String,
        pid: Int32,
        tracked: (main: LiveWindow, children: [(panel: FreeCADChildPanel, window: LiveWindow)])
    )? {
        guard maxAttempts > 0 else {
            return nil
        }

        for attempt in 1...maxAttempts {
            guard let activation = activateFirstAvailableApp(bundleIDs: freeCADBundleIDs) else {
                continue
            }

            var readyTracked:
                (
                    main: LiveWindow,
                    children: [(panel: FreeCADChildPanel, window: LiveWindow)]
                )?

            let scenarioReady = waitUntil(timeout: 25.0) {
                guard let tracked = self.selectFreeCADScenarioWindows(pid: activation.pid) else {
                    return false
                }
                readyTracked = tracked
                return true
            }

            if scenarioReady, let readyTracked {
                return (bundleID: activation.bundleID, pid: activation.pid, tracked: readyTracked)
            }

            // FreeCAD sometimes launches without exposing all child/tool windows
            // on the first activation; recycle once before failing the scenario.
            quitApp(bundleID: activation.bundleID, pid: activation.pid)
            _ = waitUntil(timeout: 4.0) {
                self.runningAppPID(bundleID: activation.bundleID) == nil
            }

            if attempt < maxAttempts {
                pauseForVisualConfirmation(duration: 0.5)
            }
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

    private func isWindowOnScreen(_ window: AXUIElement, ownerPID: Int32? = nil) -> Bool {
        guard let number = windowNumber(of: window) else {
            return isWindowVisibleWithoutWindowNumber(window, ownerPID: ownerPID)
        }
        if onScreenWindowNumbers().contains(number) {
            return true
        }
        return isWindowVisibleWithoutWindowNumber(window, ownerPID: ownerPID)
    }

    private func onScreenWindowNumbers() -> Set<Int> {
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

    private func isWindowVisibleWithoutWindowNumber(_ window: AXUIElement, ownerPID: Int32?) -> Bool
    {
        guard
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]],
            let frame = frameForWindow(window)
        else {
            return false
        }

        let title = stringAttribute(window: window, attribute: kAXTitleAttribute as CFString)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return info.contains { entry in
            if let ownerPID {
                guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
                else {
                    return false
                }
            }

            guard let bounds = windowBounds(from: entry) else {
                return false
            }

            guard frameDistance(bounds, frame) <= 24 else {
                return false
            }

            guard let title, !title.isEmpty else {
                return true
            }

            let entryTitle = (entry[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            guard let entryTitle, !entryTitle.isEmpty else {
                return true
            }

            return entryTitle.contains(title) || title.contains(entryTitle)
        }
    }

    private func windowBounds(from entry: [String: Any]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    @discardableResult
    private func switchWorkspace(_ direction: WorkspaceDirection) -> Bool {
        let keyCode = direction == .left ? 123 : 124
        let switched = runAppleScript(
            """
            tell application "System Events"
                key code \(keyCode) using control down
            end tell
            """)
        guard switched else {
            return false
        }
        pauseForVisualConfirmation(duration: 0.5)
        return true
    }

    private func escapedAppleScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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

    private func findWindow(pid: Int32, titleHint: String) -> LiveWindow? {
        liveWindows(pid: pid).first(where: { window in
            (window.title ?? "").lowercased().contains(titleHint)
        })
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

    private func boolAttribute(window: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func isWindowFullScreen(_ window: AXUIElement) -> Bool {
        boolAttribute(window: window, attribute: "AXFullScreen" as CFString) ?? false
    }

    @discardableResult
    private func setWindowFullScreen(_ window: AXUIElement, bundleID: String, fullScreen: Bool)
        -> Bool
    {
        let targetValue: CFBoolean = fullScreen ? kCFBooleanTrue : kCFBooleanFalse
        let attribute = "AXFullScreen" as CFString
        let result = AXUIElementSetAttributeValue(window, attribute, targetValue)
        if result == .success {
            return true
        }

        if isWindowFullScreen(window) == fullScreen {
            return true
        }

        guard runAppleScript("tell application id \"\(bundleID)\" to activate") else {
            return false
        }
        pauseForVisualConfirmation(duration: 0.5)

        return runAppleScript(
            """
            tell application "System Events"
                keystroke "f" using {control down, command down}
            end tell
            """
        )
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

    private func resetScriptedScenarioAppState(bundleIDs: [String]) {
        for bundleID in bundleIDs {
            while let app = runningApplication(bundleID: bundleID) {
                quitApp(bundleID: bundleID, pid: app.processIdentifier)
            }
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

    private func terminateAllStayProcesses() {
        for app in matchingStayApplications() {
            _ = app.terminate()
        }

        let terminatedGracefully = waitUntil(timeout: 3.0) {
            self.matchingStayApplications().isEmpty
        }

        if !terminatedGracefully {
            for app in matchingStayApplications() {
                _ = app.forceTerminate()
            }
        }

        _ = runCommand("/usr/bin/pkill", ["-x", StayProcessIdentity.executableName])
    }

    private func matchingStayApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            StayProcessIdentity.matches(
                RunningProcessDescriptor(
                    localizedName: app.localizedName,
                    bundleIdentifier: app.bundleIdentifier,
                    executableName: app.executableURL?.lastPathComponent
                )
            )
        }
    }

    @discardableResult
    private func runCommand(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }

    private struct LiveWindow {
        let element: AXUIElement
        let number: Int?
        let title: String?
        let role: String?
        let subrole: String?
        let frame: CGRect
    }

    private enum WorkspaceDirection {
        case left
        case right
    }

    private final class InMemorySnapshotRepository: SnapshotRepository {
        private var snapshots: [WindowSnapshot] = []

        func load() -> [WindowSnapshot] {
            snapshots
        }

        func save(_ snapshots: [WindowSnapshot]) {
            self.snapshots = snapshots
        }
    }

    private final class ManualScheduler: SleepWakeScheduling {
        private final class ManualTask: CancellableTask {
            var isCancelled = false

            func cancel() {
                isCancelled = true
            }
        }

        private var queued: [(task: ManualTask, action: () -> Void)] = []

        @discardableResult
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CancellableTask
        {
            let task = ManualTask()
            queued.append((task: task, action: action))
            return task
        }

        func runNext() {
            guard !queued.isEmpty else {
                return
            }
            let next = queued.removeFirst()
            guard !next.task.isCancelled else {
                return
            }
            next.action()
        }
    }
}
