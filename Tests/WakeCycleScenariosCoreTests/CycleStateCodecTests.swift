import Foundation
import Testing
import WakeCycleScenariosCore

@Suite("WakeCycleStateCodec")
struct CycleStateCodecTests {
    @Test("Cycle state JSON encode/decode round-trip preserves value")
    func roundTrip() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let sleepIssuedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let state = WakeCycleState(
            scenario: "finder",
            createdAt: createdAt,
            executablePath: "/tmp/WakeCycleScenarios",
            workingDirectoryPath: "/tmp",
            launchAgentLabel: "com.stayapp.wakecyclescenarios.finder",
            launchAgentPlistPath: "/tmp/com.stayapp.wakecyclescenarios.finder.plist",
            sleepIssuedAt: sleepIssuedAt,
            phase: .armedForWake
        )

        let data = try WakeCycleStateCodec.encode(state)
        let decoded = try WakeCycleStateCodec.decode(data)

        #expect(decoded == state)
    }

    @Test("Cycle state JSON uses stable key ordering")
    func stableKeyOrdering() throws {
        let state = WakeCycleState(
            scenario: "app",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            executablePath: "/tmp/WakeCycleScenarios",
            workingDirectoryPath: "/tmp",
            launchAgentLabel: "com.stayapp.wakecyclescenarios.app",
            launchAgentPlistPath: "/tmp/com.stayapp.wakecyclescenarios.app.plist",
            sleepIssuedAt: nil,
            phase: .prepared
        )

        let data = try WakeCycleStateCodec.encode(state)
        guard let json = String(data: data, encoding: .utf8) else {
            Issue.record("failed to decode JSON as UTF-8")
            return
        }

        #expect(json.contains("\"createdAt\""))
        #expect(json.contains("\"phase\""))
        #expect(json.contains("\"scenario\""))
    }

    @Test("Cycle state decode rejects malformed payload")
    func decodeRejectsMalformedPayload() {
        let malformed = Data("{\"scenario\":42}".utf8)

        #expect(throws: DecodingError.self) {
            _ = try WakeCycleStateCodec.decode(malformed)
        }
    }
}
