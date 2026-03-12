import Foundation
import Testing

@testable import Stay

@Suite("SeparateSpacesPolicy")
struct SeparateSpacesPolicyTests {
    @Test("Boolean false for spans-displays means separate spaces is enabled")
    func boolFalseMeansEnabled() {
        let preference = SeparateSpacesPreference(spansDisplaysValue: false)
        #expect(preference == .enabled)
    }

    @Test("Boolean true for spans-displays means separate spaces is disabled")
    func boolTrueMeansDisabled() {
        let preference = SeparateSpacesPreference(spansDisplaysValue: true)
        #expect(preference == .disabled)
    }

    @Test("Numeric zero for spans-displays means separate spaces is enabled")
    func zeroMeansEnabled() {
        let preference = SeparateSpacesPreference(spansDisplaysValue: 0)
        #expect(preference == .enabled)
    }

    @Test("Numeric one for spans-displays means separate spaces is disabled")
    func oneMeansDisabled() {
        let preference = SeparateSpacesPreference(spansDisplaysValue: 1)
        #expect(preference == .disabled)
    }

    @Test("Unknown spans-displays values stay unknown")
    func unknownValueRemainsUnknown() {
        let preference = SeparateSpacesPreference(spansDisplaysValue: "maybe")
        #expect(preference == .unknown)
    }

    @Test("Reader maps persistent-domain spans-displays into preference")
    func readerMapsPersistentDomainValue() {
        let domainName = "SeparateSpacesPolicyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domainName) else {
            Issue.record("Expected UserDefaults suite for test domain")
            return
        }

        defaults.setPersistentDomain(["spans-displays": false], forName: domainName)
        defer {
            defaults.removePersistentDomain(forName: domainName)
        }

        let reader = MacOSSeparateSpacesPreferenceReader(
            defaults: defaults,
            domainName: domainName
        )

        #expect(reader.currentPreference() == .enabled)
    }

    @Test("Suspension policy stands down only when separate spaces is enabled")
    func policySuspendsOnlyWhenEnabled() {
        let suspendedPolicy = SeparateSpacesSuspensionPolicy(
            preferenceReader: StubPreferenceReader(preference: .enabled)
        )
        #expect(suspendedPolicy.shouldSuspendStay())

        let activePolicy = SeparateSpacesSuspensionPolicy(
            preferenceReader: StubPreferenceReader(preference: .disabled)
        )
        #expect(!activePolicy.shouldSuspendStay())

        let unknownPolicy = SeparateSpacesSuspensionPolicy(
            preferenceReader: StubPreferenceReader(preference: .unknown)
        )
        #expect(!unknownPolicy.shouldSuspendStay())
    }
}

private struct StubPreferenceReader: SeparateSpacesPreferenceReading {
    let preference: SeparateSpacesPreference

    func currentPreference() -> SeparateSpacesPreference {
        preference
    }
}
