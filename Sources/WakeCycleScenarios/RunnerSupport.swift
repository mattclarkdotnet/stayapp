import AppKit
import CoreGraphics
import Foundation

// Design intent: keep scenario orchestration readable by isolating runner-wide
// support concerns (polling, persistence, scripting, process invocation).
extension WakeCycleScenarioRunner {
    func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.1, condition: () -> Bool) -> Bool {
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

    func sleepRunLoop(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    func persistState(_ state: ScenarioState, to url: URL) throws {
        try writeJSON(state, to: url)
    }

    func loadState(from url: URL) throws -> ScenarioState {
        try readJSON(ScenarioState.self, from: url)
    }

    func persistReport(_ report: ScenarioReport, to url: URL) throws {
        try writeJSON(report, to: url)
    }

    func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    func cleanupCreatedPaths(_ paths: [String]) {
        for path in paths {
            try? fileManager.removeItem(atPath: path)
        }
    }

    @discardableResult
    func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    @discardableResult
    func runCommand(_ launchPath: String, _ arguments: [String]) -> Int32 {
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

    func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func normalized(_ value: String?) -> String? {
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
    var area: CGFloat {
        guard !isNull, width > 0, height > 0 else {
            return 0
        }
        return width * height
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}
