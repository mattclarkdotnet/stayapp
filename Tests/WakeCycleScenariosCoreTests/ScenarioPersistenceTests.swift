import CoreGraphics
import Foundation
import Testing
import WakeCycleScenariosCore

@Suite("ScenarioPersistence")
struct ScenarioPersistenceTests {
    @Test("CodableRect preserves CoreGraphics values")
    func codableRectRoundTrip() {
        let frame = CGRect(x: 101.5, y: 222.25, width: 880, height: 640)
        let codable = CodableRect(frame)
        #expect(codable.cgRect == frame)
    }

    @Test("Scenario state JSON encode/decode round-trip preserves value")
    func scenarioStateRoundTrip() throws {
        let state = ScenarioState(
            scenario: "finder",
            bundleID: "com.apple.finder",
            trackedBundleIDs: ["com.apple.finder"],
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000),
            trackedWindows: [
                TrackedWindow(
                    appBundleID: "com.apple.finder",
                    titleHint: "window one",
                    expectedDisplayID: 1,
                    expectedFrame: CodableRect(x: 10, y: 20, width: 900, height: 700)
                ),
                TrackedWindow(
                    appBundleID: "com.apple.finder",
                    titleHint: "window two",
                    expectedDisplayID: 5,
                    expectedFrame: CodableRect(x: 20, y: 30, width: 800, height: 600)
                ),
            ],
            createdPaths: ["/tmp/finder-one", "/tmp/finder-two"]
        )

        let data = try ScenarioStateCodec.encode(state)
        let decoded = try ScenarioStateCodec.decode(data)

        #expect(decoded == state)
    }

    @Test("Scenario report JSON encode/decode round-trip preserves value")
    func scenarioReportRoundTrip() throws {
        let report = ScenarioReport(
            scenario: "kicad",
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_500),
            passed: true,
            details: ["all tracked windows restored to expected displays"]
        )

        let data = try ScenarioReportCodec.encode(report)
        let decoded = try ScenarioReportCodec.decode(data)

        #expect(decoded == report)
    }
}
