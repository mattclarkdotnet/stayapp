import AppKit
import Foundation

// Design intent: keep environment preconditions and scenario-specific window
// creation scripts separate from high-level command orchestration.
extension WakeCycleScenarioRunner {
    func ensurePrerequisites() throws {
        guard AXIsProcessTrusted() else {
            throw RunnerError.failed("Accessibility permission is required")
        }
        try fileManager.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
    }

    func validatedExternalDisplays() throws -> [ScreenDisplay] {
        let sortedScreens = NSScreen.screens.sorted { lhs, rhs in
            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.frame.minY < rhs.frame.minY
        }

        guard sortedScreens.count == 2 else {
            throw RunnerError.failed(
                "expected exactly two active displays; found \(sortedScreens.count)")
        }

        var result: [ScreenDisplay] = []
        for screen in sortedScreens {
            guard let id = displayID(for: screen) else {
                throw RunnerError.failed("could not determine NSScreenNumber")
            }
            guard CGDisplayIsBuiltin(id) == 0 else {
                throw RunnerError.failed(
                    "built-in display detected (id \(id)); scenario expects external-only")
            }
            result.append((screen: screen, id: id))
        }
        return result
    }

    func primarySecondaryDisplays(from displays: [ScreenDisplay]) throws
        -> (primary: ScreenDisplay, secondary: ScreenDisplay)
    {
        guard displays.count == 2 else {
            throw RunnerError.failed("expected exactly two displays")
        }
        guard let primaryIndex = displays.firstIndex(where: { CGDisplayIsMain($0.id) != 0 }) else {
            throw RunnerError.failed("could not identify primary macOS display")
        }
        let secondaryIndex = primaryIndex == 0 ? 1 : 0
        return (primary: displays[primaryIndex], secondary: displays[secondaryIndex])
    }

    func createScenarioWindows(scenario: Scenario) throws -> (
        script: String, titleHints: [String], createdPaths: [String]
    ) {
        let runID = String(UUID().uuidString.prefix(8)).lowercased()

        switch scenario {
        case .finder:
            let dirOne = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-finder-\(runID)-one", isDirectory: true)
            let dirTwo = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-finder-\(runID)-two", isDirectory: true)
            try fileManager.createDirectory(at: dirOne, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dirTwo, withIntermediateDirectories: true)

            let script = """
                tell application id "com.apple.finder"
                    activate
                    make new Finder window to (POSIX file "\(escaped(dirOne.path))")
                    make new Finder window to (POSIX file "\(escaped(dirTwo.path))")
                end tell
                """

            return (
                script,
                [dirOne.lastPathComponent.lowercased(), dirTwo.lastPathComponent.lowercased()],
                [dirOne.path, dirTwo.path]
            )

        case .app:
            let fileOne = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-textedit-\(runID)-one.txt")
            let fileTwo = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stay-textedit-\(runID)-two.txt")
            try "Scenario file 1\n".write(to: fileOne, atomically: true, encoding: .utf8)
            try "Scenario file 2\n".write(to: fileTwo, atomically: true, encoding: .utf8)

            let script = """
                tell application id "com.apple.TextEdit"
                    activate
                    open POSIX file "\(escaped(fileOne.path))"
                    open POSIX file "\(escaped(fileTwo.path))"
                end tell
                """

            return (
                script,
                [fileOne.lastPathComponent.lowercased(), fileTwo.lastPathComponent.lowercased()],
                [fileOne.path, fileTwo.path]
            )
        case .freecad:
            throw RunnerError.failed(
                "FreeCAD scenario uses explicit window selection, not scripted creation")
        case .kicad:
            throw RunnerError.failed(
                "KiCad scenario uses explicit window selection, not scripted creation")
        }
    }
}
