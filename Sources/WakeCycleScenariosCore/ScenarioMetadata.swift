import Foundation

extension WakeCycleScenario {
    /// Primary bundle identifier for the scenario's target app.
    public var bundleID: String {
        candidateBundleIDs[0]
    }

    /// Candidate bundle identifiers accepted for the scenario.
    public var candidateBundleIDs: [String] {
        switch self {
        case .finder:
            return ["com.apple.finder"]
        case .app:
            return ["com.apple.TextEdit"]
        case .freecad:
            return ["org.freecad.FreeCAD", "org.freecadweb.FreeCAD"]
        case .kicad:
            return ["org.kicad.kicad", "org.kicad.kicad-nightly"]
        }
    }

    /// Human-readable app name used in console output.
    public var appName: String {
        switch self {
        case .finder:
            return "Finder"
        case .app:
            return "TextEdit"
        case .freecad:
            return "FreeCAD"
        case .kicad:
            return "KiCad"
        }
    }
}
