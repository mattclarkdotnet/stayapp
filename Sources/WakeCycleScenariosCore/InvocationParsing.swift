import Foundation

/// Top-level CLI subcommands supported by `WakeCycleScenarios`.
public enum WakeCycleCommand: String, Codable, Equatable, Sendable {
    case prepare
    case verify
    case cycle
    case resume
    case awakeDisplay = "awake-display"
}

/// Scenario identifiers accepted by `WakeCycleScenarios`.
public enum WakeCycleScenario: String, Codable, Equatable, Sendable {
    case finder
    case app
    case appWorkspace = "app-workspace"
    case freecad
    case kicad
}

/// Parsed wake-cycle CLI invocation options.
public struct WakeCycleInvocation: Equatable, Sendable {
    public let command: WakeCycleCommand
    public let scenario: WakeCycleScenario
    public let shouldSleep: Bool
    public let checkOnly: Bool

    /// Creates a parsed invocation model used by command routing.
    public init(
        command: WakeCycleCommand,
        scenario: WakeCycleScenario,
        shouldSleep: Bool,
        checkOnly: Bool
    ) {
        self.command = command
        self.scenario = scenario
        self.shouldSleep = shouldSleep
        self.checkOnly = checkOnly
    }
}

/// Parse failures returned by `WakeCycleInvocationParser`.
public enum WakeCycleInvocationParseError: Error, Equatable, Sendable {
    case usage
    case unknownCommand(String)
    case unknownScenario(String)
    case unknownOptions([String])
}

/// Parser for wake-cycle command-line invocations.
public enum WakeCycleInvocationParser {
    /// Parses raw process arguments into a validated invocation model.
    public static func parse(arguments: [String]) throws -> WakeCycleInvocation {
        guard arguments.count >= 3 else {
            throw WakeCycleInvocationParseError.usage
        }

        let rawCommand = arguments[1].lowercased()
        guard let command = WakeCycleCommand(rawValue: rawCommand) else {
            throw WakeCycleInvocationParseError.unknownCommand(rawCommand)
        }

        let rawScenario = arguments[2].lowercased()
        guard let scenario = WakeCycleScenario(rawValue: rawScenario) else {
            throw WakeCycleInvocationParseError.unknownScenario(rawScenario)
        }

        let options = Array(arguments.dropFirst(3))
        switch command {
        case .prepare:
            let unknown = options.filter { $0 != "--no-sleep" }
            guard unknown.isEmpty else {
                throw WakeCycleInvocationParseError.unknownOptions(unknown)
            }
            return WakeCycleInvocation(
                command: command,
                scenario: scenario,
                shouldSleep: !options.contains("--no-sleep"),
                checkOnly: false
            )
        case .verify:
            let unknown = options.filter { $0 != "--check-only" }
            guard unknown.isEmpty else {
                throw WakeCycleInvocationParseError.unknownOptions(unknown)
            }
            return WakeCycleInvocation(
                command: command,
                scenario: scenario,
                shouldSleep: false,
                checkOnly: options.contains("--check-only")
            )
        case .cycle, .resume, .awakeDisplay:
            guard options.isEmpty else {
                throw WakeCycleInvocationParseError.unknownOptions(options)
            }
            return WakeCycleInvocation(
                command: command,
                scenario: scenario,
                shouldSleep: false,
                checkOnly: false
            )
        }
    }
}
