import Foundation

// Design intent: centralize file/label path construction for scenario state
// so cycle/prepare/verify flows share one canonical path layout.
extension WakeCycleScenarioRunner {
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

    func cycleStateURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-cycle.json")
    }

    func launchAgentLabel(for scenario: Scenario) -> String {
        "com.stayapp.wakecyclescenarios.\(scenario.rawValue)"
    }

    func launchAgentPlistURL(for scenario: Scenario) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel(for: scenario)).plist")
    }
}
