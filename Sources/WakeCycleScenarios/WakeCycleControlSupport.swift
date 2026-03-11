import AppKit
import Foundation

// Design intent: isolate wake-cycle control plumbing (state persistence,
// wake/session signal waiting, launch-agent fallback lifecycle).
extension WakeCycleScenarioRunner {
    func persistCycleState(_ state: WakeCycleState, to url: URL) throws {
        try writeJSON(state, to: url)
    }

    func loadCycleState(from url: URL) throws -> WakeCycleState {
        try readJSON(WakeCycleState.self, from: url)
    }

    func resolvedExecutablePath() -> String {
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

    func waitForWakeOrSessionSignal(timeout: TimeInterval) -> String? {
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

    func canResumeVerify(for state: WakeCycleState) -> Bool {
        guard let sleepIssuedAt = state.sleepIssuedAt else {
            return false
        }

        // LaunchAgent fallback may run before the wake boundary has completed.
        // Enforce a minimum delay so resume does not verify stale pre-sleep layout state.
        let elapsed = Date().timeIntervalSince(sleepIssuedAt)
        return elapsed >= 45
    }

    func installWakeResumeLaunchAgent(for scenario: Scenario, state: WakeCycleState) throws {
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

    func uninstallWakeResumeLaunchAgent(for scenario: Scenario, state: WakeCycleState) {
        _ = scenario
        let plistURL = URL(fileURLWithPath: state.launchAgentPlistPath)
        let domain = "gui/\(getuid())"
        _ = runCommand("/bin/launchctl", ["bootout", domain, state.launchAgentLabel])
        try? fileManager.removeItem(at: plistURL)
    }
}
