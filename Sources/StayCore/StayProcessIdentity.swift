import Foundation

public struct RunningProcessDescriptor: Equatable, Sendable {
    public let localizedName: String?
    public let bundleIdentifier: String?
    public let executableName: String?

    public init(
        localizedName: String?,
        bundleIdentifier: String?,
        executableName: String?
    ) {
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
    }
}

// Design goal: keep the definition of "which process counts as Stay?" in pure
// logic so every test runner can share the same cleanup rules.
public enum StayProcessIdentity {
    public static let currentBundleIdentifier = "net.mattclark.stay"
    public static let legacyBundleIdentifier = "com.stay.app"
    public static let executableName = "Stay"

    public static func matches(_ descriptor: RunningProcessDescriptor) -> Bool {
        if descriptor.bundleIdentifier == currentBundleIdentifier
            || descriptor.bundleIdentifier == legacyBundleIdentifier
        {
            return true
        }

        if descriptor.executableName == executableName {
            return true
        }

        return descriptor.localizedName == executableName
    }
}
