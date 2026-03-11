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

    private typealias ScreenDisplay = (screen: NSScreen, id: UInt32)
    private typealias TitleDisplayExpectation = (titleHint: String, displayID: UInt32)
    private typealias BundlePID = (bundleID: String, pid: Int32)

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

    private var scenarioDirectory: URL {
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

        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("State file: \(stateURL(for: scenario).path)")
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

        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("State file: \(stateURL(for: scenario).path)")
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

        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for KiCad.")
        print("State file: \(stateURL(for: scenario).path)")
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

        // LaunchAgent is loaded immediately; avoid resuming verify before the sleep has actually happened.
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

    private func ensurePrerequisites() throws {
        guard AXIsProcessTrusted() else {
            throw RunnerError.failed("Accessibility permission is required")
        }
        try fileManager.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
    }

    private func validatedExternalDisplays() throws -> [ScreenDisplay] {
        let sortedScreens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }

        guard sortedScreens.count == 2 else {
            throw RunnerError.failed(
                "expected exactly two active displays; found \(sortedScreens.count)")
        }

        var result: [ScreenDisplay] = []
        for screen in sortedScreens {
            guard let id = displayID(for: screen) else {
                throw RunnerError.failed("could not determine NSScreenNumber")
            }
            guard CGDisplayIsBuiltin(id) == 0 else {
                throw RunnerError.failed(
                    "built-in display detected (id \(id)); scenario expects external-only")
            }
            result.append((screen: screen, id: id))
        }
        return result
    }

    private func primarySecondaryDisplays(from displays: [ScreenDisplay]) throws
        -> (primary: ScreenDisplay, secondary: ScreenDisplay)
    {
        guard displays.count == 2 else {
            throw RunnerError.failed("expected exactly two displays")
        }
        guard let primaryIndex = displays.firstIndex(where: { CGDisplayIsMain($0.id) != 0 }) else {
            throw RunnerError.failed("could not identify primary macOS display")
        }
        let secondaryIndex = primaryIndex == 0 ? 1 : 0
        return (primary: displays[primaryIndex], secondary: displays[secondaryIndex])
    }

    private func createScenarioWindows(scenario: Scenario) throws -> (
        script: String, titleHints: [String], createdPaths: [String]
    ) {
        let runID = String(UUID().uuidString.prefix(8)).lowercased()

        switch scenario {
        case .finder:
            let dirOne = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-finder-\(runID)-one", isDirectory: true)
            let dirTwo = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-finder-\(runID)-two", isDirectory: true)
            try fileManager.createDirectory(at: dirOne, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dirTwo, withIntermediateDirectories: true)

            let script = """
                tell application id "com.apple.finder"
                    activate
                    make new Finder window to (POSIX file "\(escaped(dirOne.path))")
                    make new Finder window to (POSIX file "\(escaped(dirTwo.path))")
                end tell
                """

            return (
                script,
                [dirOne.lastPathComponent.lowercased(), dirTwo.lastPathComponent.lowercased()],
                [dirOne.path, dirTwo.path]
            )

        case .app:
            let fileOne = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-textedit-\(runID)-one.txt")
            let fileTwo = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-textedit-\(runID)-two.txt")
            try "Scenario file 1\n".write(to: fileOne, atomically: true, encoding: .utf8)
            try "Scenario file 2\n".write(to: fileTwo, atomically: true, encoding: .utf8)

            let script = """
                tell application id "com.apple.TextEdit"
                    activate
                    open POSIX file "\(escaped(fileOne.path))"
                    open POSIX file "\(escaped(fileTwo.path))"
                end tell
                """

            return (
                script,
                [fileOne.lastPathComponent.lowercased(), fileTwo.lastPathComponent.lowercased()],
                [fileOne.path, fileTwo.path]
            )
        case .freecad:
            throw RunnerError.failed(
                "FreeCAD scenario uses explicit window selection, not scripted creation")
        case .kicad:
            throw RunnerError.failed(
                "KiCad scenario uses explicit window selection, not scripted creation")
        }
    }

    private func ensureAppsRunning(bundleIDs: [String]) throws -> [Int32] {
        try bundleIDs.map { try ensureAppRunning(bundleID: $0) }
    }

    private func ensureAppRunning(bundleIDs: [String], appName: String) throws -> BundlePID {
        if let resolved = resolveRunningOrLaunchPID(bundleIDs: bundleIDs) {
            return resolved
        }

        throw RunnerError.failed("could not launch \(appName) using bundle IDs \(bundleIDs)")
    }

    private func ensureAppRunning(scenario: Scenario) throws -> BundlePID {
        if let resolved = resolveRunningOrLaunchPID(bundleIDs: scenario.candidateBundleIDs) {
            return resolved
        }

        throw RunnerError.failed(
            "could not launch app \(scenario.appName) using bundle IDs \(scenario.candidateBundleIDs)"
        )
    }

    private func ensureAppRunning(bundleID: String) throws -> Int32 {
        guard let resolved = resolveRunningOrLaunchPID(bundleIDs: [bundleID]) else {
            throw RunnerError.failed("could not launch app \(bundleID)")
        }
        return resolved.pid
    }

    private func resolveRunningOrLaunchPID(bundleIDs: [String]) -> BundlePID? {
        for bundleID in bundleIDs {
            if let running = runningApplication(bundleID: bundleID) {
                _ = running.activate()
                return (bundleID: bundleID, pid: running.processIdentifier)
            }
        }

        for bundleID in bundleIDs {
            guard runAppleScript("tell application id \"\(bundleID)\" to activate") else {
                continue
            }
            if let pid = waitForPID(bundleID: bundleID, timeout: 10) {
                return (bundleID: bundleID, pid: pid)
            }
        }

        return nil
    }

    private func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleID
        })
    }

    private func waitForPID(bundleID: String, timeout: TimeInterval) -> Int32? {
        var pid: Int32?
        _ = waitUntil(timeout: timeout) {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                !$0.isTerminated && $0.bundleIdentifier == bundleID
            }) {
                pid = running.processIdentifier
                return true
            }
            return false
        }
        return pid
    }

    private func liveWindows(pid: Int32) -> [LiveWindow] {
        let appBundleID = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.processIdentifier == pid
        })?.bundleIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else {
            return []
        }

        return windows.compactMap { element in
            guard isFrameSettable(element), let frame = frameForWindow(element) else {
                return nil
            }

            let title = stringValue(of: element, attribute: kAXTitleAttribute as CFString)
            let role = stringValue(of: element, attribute: kAXRoleAttribute as CFString)
            let subrole = stringValue(of: element, attribute: kAXSubroleAttribute as CFString)

            if normalized(title) == "desktop" {
                return nil
            }

            return LiveWindow(
                element: element,
                appPID: pid,
                appBundleID: appBundleID,
                number: windowNumber(of: element),
                title: title,
                role: role,
                subrole: subrole,
                frame: frame
            )
        }
    }

    private func liveWindows(pids: [Int32]) -> [LiveWindow] {
        pids.flatMap { liveWindows(pid: $0) }
    }

    private func primarySettableWindow(pid: Int32) -> LiveWindow? {
        liveWindows(pid: pid).max(by: { windowArea($0.frame) < windowArea($1.frame) })
    }

    private func newWindows(current: [LiveWindow], baseline: [LiveWindow]) -> [LiveWindow] {
        current.filter { currentWindow in
            !baseline.contains(where: { baselineWindow in
                CFEqual(currentWindow.element, baselineWindow.element)
            })
        }
    }

    private func matchingWindows(_ windows: [LiveWindow], titleHints: [String]) -> [LiveWindow] {
        windows.filter { window in
            guard let title = normalized(window.title) else {
                return false
            }
            return titleHints.contains(where: { title.contains($0) })
        }
    }

    private func bestWindow(matchingTitleHint hint: String, in windows: [LiveWindow]) -> LiveWindow?
    {
        windows.first(where: { normalized($0.title)?.contains(hint) == true })
    }

    private func selectFreeCADScenarioWindows(pid: Int32) -> (
        main: LiveWindow, children: [(panel: FreeCADChildPanel, window: LiveWindow)]
    )? {
        let windows = liveWindows(pid: pid)
        guard windows.count >= 5 else {
            return nil
        }

        var remaining = windows
        var children: [(panel: FreeCADChildPanel, window: LiveWindow)] = []
        children.reserveCapacity(FreeCADChildPanel.allCases.count)

        for panel in FreeCADChildPanel.allCases {
            guard let best = bestFreeCADChildWindow(for: panel, in: remaining) else {
                return nil
            }
            children.append((panel: panel, window: best))
            remaining.removeAll(where: { candidate in
                CFEqual(candidate.element, best.element)
            })
        }

        guard let main = chooseFreeCADMainWindow(from: remaining) else {
            return nil
        }

        return (main: main, children: children)
    }

    private func chooseFreeCADMainWindow(from windows: [LiveWindow]) -> LiveWindow? {
        guard !windows.isEmpty else {
            return nil
        }
        let titled = windows.filter { normalized($0.title)?.contains("freecad") == true }
        let pool = titled.isEmpty ? windows : titled
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
            let title = normalized(window.title)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return 0
        }
        var score = 0
        if title == panel.rawValue {
            score += 6
        }
        for keyword in panel.matchKeywords where title.contains(keyword) {
            score += 2
        }
        return score
    }

    private func waitForWindows(
        pid: Int32,
        timeout: TimeInterval,
        condition: ([LiveWindow]) -> Bool
    ) throws -> [LiveWindow] {
        var result: [LiveWindow] = []
        let satisfied = waitUntil(timeout: timeout) {
            let current = liveWindows(pid: pid)
            if condition(current) {
                result = current
                return true
            }
            return false
        }
        if !satisfied {
            throw RunnerError.failed("timed out waiting for windows")
        }
        return result
    }

    private func scenarioFrame(on screen: NSScreen, offset: Int) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(max(460, visible.width * 0.5), visible.width - 90)
        let height = min(max(340, visible.height * 0.58), visible.height - 110)
        let x = visible.minX + 50 + (CGFloat(offset) * 35)
        let y = visible.minY + 70 + (CGFloat(offset) * 25)
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
            x: visible.minX + 50 + (CGFloat(offset) * 35),
            y: visible.minY + 70 + (CGFloat(offset) * 25)
        )
        let origin = clampedRectOrigin(size: frame.size, preferred: preferred, in: visible)
        return setWindowOrigin(element, origin: origin)
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
        let preferred = CGPoint(x: visible.maxX - group.width - 40, y: visible.minY + 40)
        let targetGroupOrigin = clampedRectOrigin(
            size: group.size, preferred: preferred, in: visible)
        let delta = CGPoint(
            x: targetGroupOrigin.x - group.minX, y: targetGroupOrigin.y - group.minY)

        return windows.allSatisfy { window in
            let targetOrigin = CGPoint(
                x: window.frame.minX + delta.x,
                y: window.frame.minY + delta.y
            )
            return setWindowOrigin(window.element, origin: targetOrigin)
        }
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

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard
            let position = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue)
        if positionResult == .success && sizeResult == .success {
            return true
        }

        var mutableFrame = frame
        if let frameValue = AXValueCreate(.cgRect, &mutableFrame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue)
            if frameResult == .success {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func setWindowOrigin(_ window: AXUIElement, origin: CGPoint) -> Bool {
        var mutableOrigin = origin
        guard let position = AXValueCreate(.cgPoint, &mutableOrigin) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        if positionResult == .success {
            return true
        }

        guard var frame = frameForWindow(window) else {
            return false
        }
        frame.origin = origin
        if let frameValue = AXValueCreate(.cgRect, &frame) {
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

    private func windowArea(_ frame: CGRect) -> CGFloat {
        frame.width * frame.height
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

    private func stringValue(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
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

    private func displayID(for frame: CGRect) -> UInt32? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        let scored = screens.map { screen in
            (screen: screen, area: frame.intersection(screen.frame).area)
        }

        if let best = scored.max(by: { $0.area < $1.area }), best.area > 0 {
            return displayID(for: best.screen)
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = screens.min { lhs, rhs in
            distanceSquared(center, lhs.frame.center) < distanceSquared(center, rhs.frame.center)
        }
        return nearest.flatMap(displayID(for:))
    }

    private func verifyTrackedWindows(
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

    private func verificationMismatches(
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

    private func bestWindowForTracked(_ tracked: TrackedWindow, windows: [LiveWindow])
        -> LiveWindow?
    {
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

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    private func waitForDisplays(
        pid: Int32,
        expected: [TitleDisplayExpectation],
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

    private func waitForDisplayReadiness(_ requiredDisplays: Set<UInt32>, timeout: TimeInterval)
        -> Bool
    {
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

    private func waitForDisplayReadinessWithProgress(
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

    private func waitForAppWindowReadinessWithProgress(
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        timeout: TimeInterval
    ) -> Bool {
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

    private func waitForVerificationWithProgress(
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

    private func restoreTrackedWindowsWithProgress(
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

    private func applyTrackedFrames(
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

    private func perturbOneWindowOffExpectedDisplay(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pids: [Int32],
        displays: [ScreenDisplay]
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

    private func assignLiveWindows(
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

    private func bestCandidateIndex(
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

    private func restoreFrame(for scenario: Scenario, tracked: TrackedWindow, live: LiveWindow)
        -> CGRect
    {
        _ = scenario
        _ = live
        return tracked.expectedFrame.cgRect
    }

    private func perturbationFrame(for scenario: Scenario, live: LiveWindow, on screen: NSScreen)
        -> CGRect
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

    private func shouldPreserveSizeOnRestore(scenario: Scenario, tracked: TrackedWindow) -> Bool {
        if scenario == .kicad {
            return true
        }
        guard scenario == .freecad else {
            return false
        }
        return FreeCADChildPanel.allCases.contains { panel in
            tracked.titleHint.contains(panel.rawValue)
        }
    }

    private func isAligned(scenario: Scenario, tracked: TrackedWindow, live: LiveWindow) -> Bool {
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

    private func isAligned(scenario: Scenario, tracked: TrackedWindow, element: AXUIElement) -> Bool
    {
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

    private func isAligned(
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

    private func frameTolerance(scenario: Scenario) -> (position: CGFloat, size: CGFloat) {
        switch scenario {
        case .finder:
            // Finder can snap by a few points after cross-display moves.
            return (position: 8, size: 12)
        case .app:
            return (position: 4, size: 6)
        case .freecad:
            return (position: 8, size: 8)
        case .kicad:
            return (position: 8, size: 8)
        }
    }

    private func frameSummary(_ frame: CGRect) -> String {
        String(
            format: "(x=%.1f y=%.1f w=%.1f h=%.1f)",
            frame.minX, frame.minY, frame.width, frame.height
        )
    }

    private func onlineDisplays() -> Set<UInt32> {
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

    private func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.1, condition: () -> Bool)
        -> Bool
    {
        if condition() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(poll))
            if condition() {
                return true
            }
        }

        return condition()
    }

    private func sleepRunLoop(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func persistState(_ state: ScenarioState, to url: URL) throws {
        try writeJSON(state, to: url)
    }

    private func loadState(from url: URL) throws -> ScenarioState {
        try readJSON(ScenarioState.self, from: url)
    }

    private func persistReport(_ report: ScenarioReport, to url: URL) throws {
        try writeJSON(report, to: url)
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func cleanupCreatedPaths(_ paths: [String]) {
        for path in paths {
            try? fileManager.removeItem(atPath: path)
        }
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

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            return nil
        }
        return value.lowercased()
    }
}

enum RunnerError: Error, LocalizedError {
    case failed(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message), .scriptFailed(let message):
            return message
        }
    }
}

extension CGRect {
    fileprivate var area: CGFloat {
        guard !isNull, width > 0, height > 0 else {
            return 0
        }
        return width * height
    }

    fileprivate var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}

@main
struct Main {
    static func main() {
        var runner = WakeCycleScenarioRunner()
        exit(runner.run())
    }
}
