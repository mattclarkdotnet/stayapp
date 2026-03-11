import Foundation

// Design intent: keep cycle/resume command orchestration isolated from top-level
// CLI parsing and prepare/verify command behavior.
extension WakeCycleScenarioRunner {
    func cycle(scenario: Scenario) throws {
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

    func resume(scenario: Scenario) throws {
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

    func persistCyclePhase(
        _ phase: WakeCyclePhase,
        sleepIssuedAt: Date?,
        state: inout WakeCycleState,
        to cycleURL: URL
    ) throws {
        state.phase = phase
        state.sleepIssuedAt = sleepIssuedAt
        try persistCycleState(state, to: cycleURL)
    }

    func configureCycleLaunchAgentFallback(
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

    func finalizeCycleSuccess(
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

    func finalizeCycleFailure(
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

    func runAutomatedVerifyAfterWake(
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

    func launchAgentFallbackIsEnabled() -> Bool {
        ProcessInfo.processInfo.environment["STAY_CYCLE_ENABLE_LAUNCH_AGENT"] == "1"
    }
}
