import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import StayCore
import WakeCycleScenariosCore

@MainActor
struct WakeCycleScenarioRunner {
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

    typealias Command = WakeCycleScenariosCore.WakeCycleCommand
    typealias Scenario = WakeCycleScenariosCore.WakeCycleScenario
    typealias CodableRect = WakeCycleScenariosCore.CodableRect
    typealias TrackedWindow = WakeCycleScenariosCore.TrackedWindow
    typealias ScenarioState = WakeCycleScenariosCore.ScenarioState
    typealias ScenarioReport = WakeCycleScenariosCore.ScenarioReport
    typealias WakeCyclePhase = WakeCycleScenariosCore.WakeCyclePhase
    typealias WakeCycleState = WakeCycleScenariosCore.WakeCycleState

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
        let invocation: WakeCycleInvocation
        do {
            invocation = try WakeCycleInvocationParser.parse(arguments: args)
        } catch WakeCycleInvocationParseError.usage {
            printUsage()
            return 2
        } catch WakeCycleInvocationParseError.unknownCommand(let rawCommand) {
            fputs("error: unknown command '\(rawCommand)'\n", stderr)
            return 1
        } catch WakeCycleInvocationParseError.unknownScenario(let rawScenario) {
            fputs("error: unknown scenario '\(rawScenario)'\n", stderr)
            return 1
        } catch WakeCycleInvocationParseError.unknownOptions(let options) {
            fputs("error: unknown option(s): \(options.joined(separator: ", "))\n", stderr)
            return 1
        } catch {
            fputs("error: \(error)\n", stderr)
            return 1
        }

        let command = invocation.command
        let scenario = invocation.scenario

        do {
            switch command {
            case .prepare:
                try prepare(scenario: scenario, shouldSleep: invocation.shouldSleep)
            case .verify:
                try verify(
                    scenario: scenario,
                    checkOnly: invocation.checkOnly,
                    timings: .manual,
                    skipPrerequisiteCheck: false
                )
            case .cycle:
                try cycle(scenario: scenario)
            case .resume:
                try resume(scenario: scenario)
            case .awakeDisplay:
                try runAwakeDisplayDisconnectScenario(scenario: scenario)
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
              swift run WakeCycleScenarios prepare <finder|app|app-workspace|freecad|kicad> [--no-sleep]
              swift run WakeCycleScenarios verify <finder|app|app-workspace|freecad|kicad> [--check-only]
              swift run WakeCycleScenarios cycle <finder|app|app-workspace|freecad|kicad>
              swift run WakeCycleScenarios awake-display <finder|app>

            Notes:
              - Requires exactly two external displays and no built-in display.
              - Requires Accessibility permission.
              - prepare creates/positions real app windows and optionally puts the Mac to sleep.
              - verify defaults to: perturb one tracked window, restore tracked windows, then verify.
              - verify --check-only performs passive post-wake validation with no perturb/restore.
              - cycle runs prepare, sleeps the machine, waits for wake/session readiness, then auto-runs verify.
              - awake-display prepares the no-sleep scenario, captures Stay snapshots, waits for a real secondary-display disconnect, verifies stale targets were pruned, then verifies the windows return after the same display reconnects.
              - optional fallback: set STAY_CYCLE_ENABLE_LAUNCH_AGENT=1 to enable LaunchAgent-based resume.
            """)
    }

}

var runner = WakeCycleScenarioRunner()
exit(runner.run())
