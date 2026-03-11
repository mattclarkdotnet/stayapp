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

    let kicadPCBBundleIDs = ["org.kicad.pcbnew", "org.kicad.pcbnew-nightly"]
    let kicadSchematicBundleIDs = ["org.kicad.eeschema", "org.kicad.eeschema-nightly"]

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

    enum WakeCyclePhase: String, Codable {
        case prepared
        case armedForWake
        case resumedInRunner
        case verifying
        case completed
        case failed
    }

    struct WakeCycleState: Codable {
        var scenario: String
        var createdAt: Date
        var executablePath: String
        var workingDirectoryPath: String
        var launchAgentLabel: String
        var launchAgentPlistPath: String
        var sleepIssuedAt: Date?
        var phase: WakeCyclePhase
    }

    struct VerifyTimingOptions {
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

    func stateURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-state.json")
    }

    func reportURL(for scenario: Scenario) -> URL {
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

}

var runner = WakeCycleScenarioRunner()
exit(runner.run())
