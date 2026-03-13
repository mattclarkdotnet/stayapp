import Foundation
import Testing

@testable import StayCore

@Suite("StayProcessIdentity")
struct StayProcessIdentityTests {
    @Test("Current bundle identifier matches Stay")
    func currentBundleIdentifierMatches() {
        #expect(
            StayProcessIdentity.matches(
                RunningProcessDescriptor(
                    localizedName: "Anything",
                    bundleIdentifier: StayProcessIdentity.currentBundleIdentifier,
                    executableName: "Other"
                )
            )
        )
    }

    @Test("Legacy bundle identifier matches Stay")
    func legacyBundleIdentifierMatches() {
        #expect(
            StayProcessIdentity.matches(
                RunningProcessDescriptor(
                    localizedName: "Anything",
                    bundleIdentifier: StayProcessIdentity.legacyBundleIdentifier,
                    executableName: "Other"
                )
            )
        )
    }

    @Test("Executable name matches Stay")
    func executableNameMatches() {
        #expect(
            StayProcessIdentity.matches(
                RunningProcessDescriptor(
                    localizedName: nil,
                    bundleIdentifier: nil,
                    executableName: StayProcessIdentity.executableName
                )
            )
        )
    }

    @Test("Unrelated process does not match Stay")
    func unrelatedProcessDoesNotMatch() {
        #expect(
            !StayProcessIdentity.matches(
                RunningProcessDescriptor(
                    localizedName: "TextEdit",
                    bundleIdentifier: "com.apple.TextEdit",
                    executableName: "TextEdit"
                )
            )
        )
    }
}
