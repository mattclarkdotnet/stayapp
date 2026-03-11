import Foundation

/// Phases for the wake-cycle automation state machine.
public enum WakeCyclePhase: String, Codable, Equatable, Sendable {
    case prepared
    case armedForWake
    case resumedInRunner
    case verifying
    case completed
    case failed
}

/// Persisted wake-cycle state shared between `cycle` and `resume` modes.
public struct WakeCycleState: Codable, Equatable, Sendable {
    public var scenario: String
    public var createdAt: Date
    public var executablePath: String
    public var workingDirectoryPath: String
    public var launchAgentLabel: String
    public var launchAgentPlistPath: String
    public var sleepIssuedAt: Date?
    public var phase: WakeCyclePhase

    /// Creates a persisted wake-cycle state record.
    public init(
        scenario: String,
        createdAt: Date,
        executablePath: String,
        workingDirectoryPath: String,
        launchAgentLabel: String,
        launchAgentPlistPath: String,
        sleepIssuedAt: Date?,
        phase: WakeCyclePhase
    ) {
        self.scenario = scenario
        self.createdAt = createdAt
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.launchAgentLabel = launchAgentLabel
        self.launchAgentPlistPath = launchAgentPlistPath
        self.sleepIssuedAt = sleepIssuedAt
        self.phase = phase
    }
}

/// JSON codec for persisted `WakeCycleState` files.
public enum WakeCycleStateCodec {
    /// Encodes wake-cycle state with stable key ordering and ISO-8601 dates.
    public static func encode(_ state: WakeCycleState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    /// Decodes wake-cycle state from JSON using ISO-8601 dates.
    public static func decode(_ data: Data) throws -> WakeCycleState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WakeCycleState.self, from: data)
    }
}
