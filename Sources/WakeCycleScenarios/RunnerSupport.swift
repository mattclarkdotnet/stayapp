import AppKit
import CoreGraphics
import Foundation
import WakeCycleScenariosCore

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
        let data = try ScenarioStateCodec.encode(state)
        try data.write(to: url, options: .atomic)
    }

    func loadState(from url: URL) throws -> ScenarioState {
        let data = try Data(contentsOf: url)
        return try ScenarioStateCodec.decode(data)
    }

    func persistReport(_ report: ScenarioReport, to url: URL) throws {
        let data = try ScenarioReportCodec.encode(report)
        try data.write(to: url, options: .atomic)
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

    func stayExecutableURL() -> URL {
        URL(fileURLWithPath: args[0])
            .deletingLastPathComponent()
            .appendingPathComponent("Stay", isDirectory: false)
    }

    func startStayIfNeeded() throws -> Process? {
        if isStayProcessRunning() {
            print("Using existing Stay process.")
            return nil
        }

        let executableURL = stayExecutableURL()
        guard fileManager.fileExists(atPath: executableURL.path) else {
            throw RunnerError.failed("could not find Stay executable at \(executableURL.path)")
        }

        let process = Process()
        process.executableURL = executableURL

        do {
            try process.run()
        } catch {
            throw RunnerError.failed("failed to start Stay: \(error.localizedDescription)")
        }

        sleepRunLoop(2.0)
        guard process.isRunning else {
            throw RunnerError.failed("Stay exited immediately after launch")
        }

        print("Started Stay process for awake-display scenario.")
        return process
    }

    func terminateStartedStayProcess(_ process: Process?) {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
    }

    func isStayProcessRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Stay"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
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
