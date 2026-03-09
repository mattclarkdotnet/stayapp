import ApplicationServices
import Foundation

// Design goal: fail safely when permissions are missing and only prompt on user-visible paths.
enum AccessibilityPermission {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
