import Foundation

// Design goal: keep the user-visible "stand down when macOS is already
// managing placement" policy isolated from the sleep/wake coordinator.
enum SeparateSpacesPreference: Equatable {
    case enabled
    case disabled
    case unknown

    init(spansDisplaysValue: Any?) {
        guard let spansDisplaysValue else {
            self = .unknown
            return
        }

        if let boolValue = spansDisplaysValue as? Bool {
            self = boolValue ? .disabled : .enabled
            return
        }

        if let numberValue = spansDisplaysValue as? NSNumber {
            self = numberValue.intValue == 0 ? .enabled : .disabled
            return
        }

        if let stringValue = spansDisplaysValue as? String {
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "0", "false", "no":
                self = .enabled
            case "1", "true", "yes":
                self = .disabled
            default:
                self = .unknown
            }
            return
        }

        self = .unknown
    }
}

protocol SeparateSpacesPreferenceReading {
    func currentPreference() -> SeparateSpacesPreference
}

struct MacOSSeparateSpacesPreferenceReader: SeparateSpacesPreferenceReading {
    private let defaults: UserDefaults
    private let domainName: String

    init(
        defaults: UserDefaults = .standard,
        domainName: String = "com.apple.spaces"
    ) {
        self.defaults = defaults
        self.domainName = domainName
    }

    func currentPreference() -> SeparateSpacesPreference {
        let domain = defaults.persistentDomain(forName: domainName)
        return SeparateSpacesPreference(spansDisplaysValue: domain?["spans-displays"])
    }
}

struct SeparateSpacesSuspensionPolicy {
    static let suspendedStatusLine = "Separate Spaces enabled: Stay paused"
    static let suspendedNotificationTitle = "Stay paused"
    static let suspendedNotificationBody =
        "macOS is already preserving window locations while Displays have separate Spaces is on. Stay will resume after you turn that setting off again."

    private let preferenceReader: any SeparateSpacesPreferenceReading

    init(preferenceReader: any SeparateSpacesPreferenceReading) {
        self.preferenceReader = preferenceReader
    }

    func shouldSuspendStay() -> Bool {
        preferenceReader.currentPreference() == .enabled
    }
}
