import Testing
import WakeCycleScenariosCore

@Suite("WakeCycleInvocationParser")
struct InvocationParsingTests {
    @Test("Prepare parses --no-sleep option")
    func prepareNoSleep() throws {
        let invocation = try WakeCycleInvocationParser.parse(arguments: [
            "WakeCycleScenarios", "prepare", "finder", "--no-sleep",
        ])

        #expect(invocation.command == .prepare)
        #expect(invocation.scenario == .finder)
        #expect(invocation.shouldSleep == false)
        #expect(invocation.checkOnly == false)
    }

    @Test("Verify parses --check-only option")
    func verifyCheckOnly() throws {
        let invocation = try WakeCycleInvocationParser.parse(arguments: [
            "WakeCycleScenarios", "verify", "app", "--check-only",
        ])

        #expect(invocation.command == .verify)
        #expect(invocation.scenario == .app)
        #expect(invocation.shouldSleep == false)
        #expect(invocation.checkOnly == true)
    }

    @Test("Usage error when args are missing")
    func usageError() {
        #expect(throws: WakeCycleInvocationParseError.usage) {
            try WakeCycleInvocationParser.parse(arguments: ["WakeCycleScenarios"])
        }
    }

    @Test("Unknown command is rejected")
    func unknownCommand() {
        #expect(throws: WakeCycleInvocationParseError.unknownCommand("bogus")) {
            try WakeCycleInvocationParser.parse(arguments: [
                "WakeCycleScenarios", "bogus", "finder",
            ])
        }
    }

    @Test("Unknown scenario is rejected")
    func unknownScenario() {
        #expect(throws: WakeCycleInvocationParseError.unknownScenario("bogus")) {
            try WakeCycleInvocationParser.parse(arguments: [
                "WakeCycleScenarios", "prepare", "bogus",
            ])
        }
    }

    @Test("Unknown options are rejected")
    func unknownOptions() {
        #expect(throws: WakeCycleInvocationParseError.unknownOptions(["--bad"])) {
            try WakeCycleInvocationParser.parse(arguments: [
                "WakeCycleScenarios", "cycle", "finder", "--bad",
            ])
        }
    }
}
