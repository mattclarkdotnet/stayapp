import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
struct WakeCycleScenarioRunner {
    enum Command: String {
        case prepare
        case verify
        case cycle
        case resume
    }

    enum Scenario: String {
        case finder
        case app
        case freecad
        case kicad

        var bundleID: String {
            candidateBundleIDs[0]
        }

        var candidateBundleIDs: [String] {
            switch self {
            case .finder:
                return ["com.apple.finder"]
            case .app:
                return ["com.apple.TextEdit"]
            case .freecad:
                return ["org.freecad.FreeCAD", "org.freecadweb.FreeCAD"]
            case .kicad:
                return ["org.kicad.kicad", "org.kicad.kicad-nightly"]
            }
        }

        var appName: String {
            switch self {
            case .finder:
                return "Finder"
            case .app:
                return "TextEdit"
            case .freecad:
                return "FreeCAD"
            case .kicad:
                return "KiCad"
            }
        }
    }

    enum FreeCADChildPanel: String, CaseIterable {
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

    private let kicadPCBBundleIDs = ["org.kicad.pcbnew", "org.kicad.pcbnew-nightly"]
    private let kicadSchematicBundleIDs = ["org.kicad.eeschema", "org.kicad.eeschema-nightly"]

    struct CodableRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct TrackedWindow: Codable {
        let appBundleID: String?
        let titleHint: String
        let expectedDisplayID: UInt32
        let expectedFrame: CodableRect
    }

    struct ScenarioState: Codable {
        let scenario: String
        let bundleID: String
        let trackedBundleIDs: [String]?
        let preparedAt: Date
        let trackedWindows: [TrackedWindow]
        let createdPaths: [String]
    }

    struct ScenarioReport: Codable {
        let scenario: String
        let verifiedAt: Date
        let passed: Bool
        let details: [String]
    }

    private enum WakeCyclePhase: String, Codable {
        case prepared
        case armedForWake
        case resumedInRunner
        case verifying
        case completed
        case failed
    }

    private struct WakeCycleState: Codable {
        var scenario: String
        var createdAt: Date
        var executablePath: String
        var workingDirectoryPath: String
        var launchAgentLabel: String
        var launchAgentPlistPath: String
        var sleepIssuedAt: Date?
        var phase: WakeCyclePhase
    }

    private struct VerifyTimingOptions {
        let displayReadinessTimeout: TimeInterval
        let appWindowReadinessTimeout: TimeInterval
        let restoreTimeout: TimeInterval
        let verificationTimeout: TimeInterval

        static let manual = VerifyTimingOptions(
            displayReadinessTimeout: 45,
            appWindowReadinessTimeout: 25,
            restoreTimeout: 20,
            verificationTimeout: 20
        )

        static let wakeCycle = VerifyTimingOptions(
            displayReadinessTimeout: 180,
            appWindowReadinessTimeout: 600,
            restoreTimeout: 25,
            verificationTimeout: 25
        )
    }

    typealias ScreenDisplay = (screen: NSScreen, id: UInt32)

    struct LiveWindow {
        let element: AXUIElement
        let appPID: Int32
        let appBundleID: String?
        let number: Int?
        let title: String?
        let role: String?
        let subrole: String?
        let frame: CGRect
    }

    let args: [String]
    let fileManager = FileManager.default

    init(args: [String] = CommandLine.arguments) {
        self.args = args
    }

    mutating func run() -> Int32 {
        guard args.count >= 3,
            let command = Command(rawValue: args[1].lowercased()),
            let scenario = Scenario(rawValue: args[2].lowercased())
        else {
            printUsage()
            return 2
        }

        do {
            let options = Array(args.dropFirst(3))
            switch command {
            case .prepare:
                let unknown = options.filter { $0 != "--no-sleep" }
                guard unknown.isEmpty else {
                    throw RunnerError.failed(
                        "unknown prepare option(s): \(unknown.joined(separator: ", "))")
                }
                let shouldSleep = !options.contains("--no-sleep")
                try prepare(scenario: scenario, shouldSleep: shouldSleep)
            case .verify:
                let unknown = options.filter { $0 != "--check-only" }
                guard unknown.isEmpty else {
                    throw RunnerError.failed(
                        "unknown verify option(s): \(unknown.joined(separator: ", "))")
                }
                let checkOnly = options.contains("--check-only")
                try verify(
                    scenario: scenario,
                    checkOnly: checkOnly,
                    timings: .manual,
                    skipPrerequisiteCheck: false
                )
            case .cycle:
                guard options.isEmpty else {
                    throw RunnerError.failed(
                        "unknown cycle option(s): \(options.joined(separator: ", "))")
                }
                try cycle(scenario: scenario)
            case .resume:
                guard options.isEmpty else {
                    throw RunnerError.failed(
                        "unknown resume option(s): \(options.joined(separator: ", "))")
                }
                try resume(scenario: scenario)
            }
            return 0
        } catch {
            fputs("error: \(error)\n", stderr)
            return 1
        }
    }

    private func printUsage() {
        print(
            """
            Usage:
              swift run WakeCycleScenarios prepare <finder|app|freecad|kicad> [--no-sleep]
              swift run WakeCycleScenarios verify <finder|app|freecad|kicad> [--check-only]
              swift run WakeCycleScenarios cycle <finder|app|freecad|kicad>

            Notes:
              - Requires exactly two external displays and no built-in display.
              - Requires Accessibility permission.
              - prepare creates/positions real app windows and optionally puts the Mac to sleep.
              - verify defaults to: perturb one tracked window, restore tracked windows, then verify.
              - verify --check-only performs passive post-wake validation with no perturb/restore.
              - cycle runs prepare, sleeps the machine, waits for wake/session readiness, then auto-runs verify.
              - optional fallback: set STAY_CYCLE_ENABLE_LAUNCH_AGENT=1 to enable LaunchAgent-based resume.
            """)
    }

    var scenarioDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Stay/WakeCycleScenarios", isDirectory: true)
    }

    private func stateURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-state.json")
    }

    private func reportURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-report.json")
    }

    private func cycleStateURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-cycle.json")
    }

    private func launchAgentLabel(for scenario: Scenario) -> String {
        "com.stayapp.wakecyclescenarios.\(scenario.rawValue)"
    }

    private func launchAgentPlistURL(for scenario: Scenario) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel(for: scenario)).plist")
    }

    private func cycle(scenario: Scenario) throws {
        try ensurePrerequisites()
        try prepare(scenario: scenario, shouldSleep: false)

        let cycleURL = cycleStateURL(for: scenario)
        let launchAgentFallbackEnabled = launchAgentFallbackIsEnabled()
        var cycleState = WakeCycleState(
            scenario: scenario.rawValue,
            createdAt: Date(),
            executablePath: resolvedExecutablePath(),
            workingDirectoryPath: fileManager.currentDirectoryPath,
            launchAgentLabel: launchAgentLabel(for: scenario),
            launchAgentPlistPath: launchAgentPlistURL(for: scenario).path,
            sleepIssuedAt: nil,
            phase: .prepared
        )
        try persistCycleState(cycleState, to: cycleURL)
        try configureCycleLaunchAgentFallback(
            enabled: launchAgentFallbackEnabled,
            scenario: scenario,
            state: cycleState
        )
        try persistCyclePhase(
            .armedForWake,
            sleepIssuedAt: Date(),
            state: &cycleState,
            to: cycleURL
        )

        print("Cycle mode: sleeping machine in 3 seconds.")
        print("After wake/login, this runner will continue automatically.")
        Thread.sleep(forTimeInterval: 3)
        _ = runCommand("/usr/bin/pmset", ["sleepnow"])

        print("Cycle mode: waiting for wake/session signals.")
        _ = waitForWakeOrSessionSignal(timeout: 20)

        try persistCyclePhase(
            .resumedInRunner,
            sleepIssuedAt: cycleState.sleepIssuedAt,
            state: &cycleState,
            to: cycleURL
        )

        do {
            try runAutomatedVerifyAfterWake(
                scenario: scenario,
                timings: .wakeCycle,
                source: "cycle-runner",
                skipPrerequisiteCheck: true
            )
            try finalizeCycleSuccess(
                scenario: scenario,
                state: &cycleState,
                cycleURL: cycleURL,
                launchAgentFallbackEnabled: launchAgentFallbackEnabled
            )
        } catch {
            finalizeCycleFailure(
                scenario: scenario,
                state: &cycleState,
                cycleURL: cycleURL,
                launchAgentFallbackEnabled: launchAgentFallbackEnabled
            )
            throw error
        }
    }

    private func resume(scenario: Scenario) throws {
        try ensurePrerequisites()
        let cycleURL = cycleStateURL(for: scenario)

        guard var cycleState = try? loadCycleState(from: cycleURL) else {
            print(
                "Resume mode: no cycle state found for scenario '\(scenario.rawValue)'; nothing to do."
            )
            return
        }

        guard cycleState.phase == .armedForWake else {
            print("Resume mode: cycle phase '\(cycleState.phase.rawValue)' is not resumable.")
            return
        }

        if !canResumeVerify(for: cycleState) {
            print("Resume mode: wake not yet confirmed; leaving cycle armed.")
            return
        }

        try persistCyclePhase(
            .verifying,
            sleepIssuedAt: cycleState.sleepIssuedAt,
            state: &cycleState,
            to: cycleURL
        )

        do {
            try runAutomatedVerifyAfterWake(
                scenario: scenario,
                timings: .wakeCycle,
                source: "launch-agent",
                skipPrerequisiteCheck: false
            )
            try finalizeCycleSuccess(
                scenario: scenario,
                state: &cycleState,
                cycleURL: cycleURL,
                launchAgentFallbackEnabled: true
            )
        } catch {
            finalizeCycleFailure(
                scenario: scenario,
                state: &cycleState,
                cycleURL: cycleURL,
                launchAgentFallbackEnabled: true
            )
            throw error
        }
    }

    private func persistCyclePhase(
        _ phase: WakeCyclePhase,
        sleepIssuedAt: Date?,
        state: inout WakeCycleState,
        to cycleURL: URL
    ) throws {
        state.phase = phase
        state.sleepIssuedAt = sleepIssuedAt
        try persistCycleState(state, to: cycleURL)
    }

    private func configureCycleLaunchAgentFallback(
        enabled: Bool,
        scenario: Scenario,
        state: WakeCycleState
    ) throws {
        guard enabled else {
            print(
                "Cycle mode: LaunchAgent fallback is disabled (set STAY_CYCLE_ENABLE_LAUNCH_AGENT=1 to enable)."
            )
            uninstallWakeResumeLaunchAgent(for: scenario, state: state)
            return
        }
        try installWakeResumeLaunchAgent(for: scenario, state: state)
    }

    private func finalizeCycleSuccess(
        scenario: Scenario,
        state: inout WakeCycleState,
        cycleURL: URL,
        launchAgentFallbackEnabled: Bool
    ) throws {
        try persistCyclePhase(
            .completed,
            sleepIssuedAt: state.sleepIssuedAt,
            state: &state,
            to: cycleURL
        )
        if launchAgentFallbackEnabled {
            uninstallWakeResumeLaunchAgent(for: scenario, state: state)
        }
        try? fileManager.removeItem(at: cycleURL)
    }

    private func finalizeCycleFailure(
        scenario: Scenario,
        state: inout WakeCycleState,
        cycleURL: URL,
        launchAgentFallbackEnabled: Bool
    ) {
        state.phase = .failed
        try? persistCycleState(state, to: cycleURL)
        if launchAgentFallbackEnabled {
            uninstallWakeResumeLaunchAgent(for: scenario, state: state)
        }
    }

    private func runAutomatedVerifyAfterWake(
        scenario: Scenario,
        timings: VerifyTimingOptions,
        source: String,
        skipPrerequisiteCheck: Bool
    ) throws {
        print("Auto-verify start (source=\(source), scenario=\(scenario.rawValue)).")
        try verify(
            scenario: scenario,
            checkOnly: false,
            timings: timings,
            skipPrerequisiteCheck: skipPrerequisiteCheck
        )
    }

    private func launchAgentFallbackIsEnabled() -> Bool {
        ProcessInfo.processInfo.environment["STAY_CYCLE_ENABLE_LAUNCH_AGENT"] == "1"
    }

    private func prepare(scenario: Scenario, shouldSleep: Bool) throws {
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

    private func prepareFreeCADScenario(
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

    private func prepareKiCadScenario(
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

    private func verify(
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

    private func performOptionalSleepAfterPrepare(shouldSleep: Bool, scenario: Scenario) {
        guard shouldSleep else {
            print("Skipped sleep (--no-sleep). Manually sleep/wake, then run verify.")
            return
        }
        print("Sleeping machine in 3 seconds. After wake/login, run:")
        print("  swift run WakeCycleScenarios verify \(scenario.rawValue)")
        Thread.sleep(forTimeInterval: 3)
        _ = runCommand("/usr/bin/pmset", ["sleepnow"])
    }

    private func printPreparedScenarioHeader(scenario: Scenario) {
        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("State file: \(stateURL(for: scenario).path)")
    }

    private func persistCycleState(_ state: WakeCycleState, to url: URL) throws {
        try writeJSON(state, to: url)
    }

    private func loadCycleState(from url: URL) throws -> WakeCycleState {
        try readJSON(WakeCycleState.self, from: url)
    }

    private func resolvedExecutablePath() -> String {
        guard let rawPath = args.first else {
            return fileManager.currentDirectoryPath
        }
        if rawPath.hasPrefix("/") {
            return rawPath
        }
        return URL(
            fileURLWithPath: rawPath,
            relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        ).standardizedFileURL.path
    }

    private func waitForWakeOrSessionSignal(timeout: TimeInterval) -> String? {
        final class SignalBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: String?

            func setIfEmpty(_ newValue: String) {
                lock.lock()
                defer { lock.unlock() }
                if value == nil {
                    value = newValue
                }
            }

            func read() -> String? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let signalBox = SignalBox()

        let observers: [Any] = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                signalBox.setIfEmpty("didWake")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                signalBox.setIfEmpty("screensDidWake")
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { _ in
                signalBox.setIfEmpty("sessionDidBecomeActive")
            },
        ]
        defer {
            for observer in observers {
                workspaceCenter.removeObserver(observer)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let observedSignal = signalBox.read() {
                print("Wake/session signal observed: \(observedSignal)")
                return observedSignal
            }
            sleepRunLoop(0.2)
        }

        print("Wake/session signal wait timed out; continuing with readiness checks.")
        return nil
    }

    private func canResumeVerify(for state: WakeCycleState) -> Bool {
        guard let sleepIssuedAt = state.sleepIssuedAt else {
            return false
        }

        // LaunchAgent fallback may run before the wake boundary has completed.
        // Enforce a minimum delay so resume does not verify stale pre-sleep layout state.
        let elapsed = Date().timeIntervalSince(sleepIssuedAt)
        return elapsed >= 45
    }

    private func installWakeResumeLaunchAgent(for scenario: Scenario, state: WakeCycleState) throws
    {
        let plistURL = URL(fileURLWithPath: state.launchAgentPlistPath)
        let launchAgentsDirectory = plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: launchAgentsDirectory, withIntermediateDirectories: true)

        let stdoutPath = scenarioDirectory.appendingPathComponent(
            "\(scenario.rawValue)-cycle-launchagent.out.log"
        ).path
        let stderrPath = scenarioDirectory.appendingPathComponent(
            "\(scenario.rawValue)-cycle-launchagent.err.log"
        ).path

        let plist: [String: Any] = [
            "Label": state.launchAgentLabel,
            "ProgramArguments": [state.executablePath, "resume", scenario.rawValue],
            "WorkingDirectory": state.workingDirectoryPath,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StartInterval": 20,
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": stdoutPath,
            "StandardErrorPath": stderrPath,
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: plistURL, options: .atomic)

        let domain = "gui/\(getuid())"
        _ = runCommand("/bin/launchctl", ["bootout", domain, state.launchAgentLabel])

        let bootstrapStatus = runCommand("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if bootstrapStatus != 0 {
            print(
                "warning: launchctl bootstrap failed for fallback resume agent (status=\(bootstrapStatus)); cycle runner will continue without agent fallback"
            )
        } else {
            print("Installed wake-cycle fallback LaunchAgent: \(state.launchAgentLabel)")
        }
    }

    private func uninstallWakeResumeLaunchAgent(for scenario: Scenario, state: WakeCycleState) {
        _ = scenario
        let plistURL = URL(fileURLWithPath: state.launchAgentPlistPath)
        let domain = "gui/\(getuid())"
        _ = runCommand("/bin/launchctl", ["bootout", domain, state.launchAgentLabel])
        try? fileManager.removeItem(at: plistURL)
    }

}

var runner = WakeCycleScenarioRunner()
exit(runner.run())
