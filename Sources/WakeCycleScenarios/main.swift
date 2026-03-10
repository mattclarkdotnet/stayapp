import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
struct WakeCycleScenarioRunner {
    enum Command: String {
        case prepare
        case verify
    }

    enum Scenario: String {
        case finder
        case app

        var bundleID: String {
            switch self {
            case .finder:
                return "com.apple.finder"
            case .app:
                return "com.apple.TextEdit"
            }
        }

        var appName: String {
            switch self {
            case .finder:
                return "Finder"
            case .app:
                return "TextEdit"
            }
        }
    }

    struct CodableRect: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ rect: CGRect) {
            x = rect.origin.x
            y = rect.origin.y
            width = rect.width
            height = rect.height
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct TrackedWindow: Codable {
        let titleHint: String
        let expectedDisplayID: UInt32
        let expectedFrame: CodableRect
    }

    struct ScenarioState: Codable {
        let scenario: String
        let bundleID: String
        let preparedAt: Date
        let trackedWindows: [TrackedWindow]
        let createdPaths: [String]
    }

    struct ScenarioReport: Codable {
        let scenario: String
        let verifiedAt: Date
        let passed: Bool
        let details: [String]
    }

    struct LiveWindow {
        let element: AXUIElement
        let title: String?
        let role: String?
        let subrole: String?
        let frame: CGRect
    }

    let args: [String]
    let fileManager = FileManager.default

    init(args: [String] = CommandLine.arguments) {
        self.args = args
    }

    mutating func run() -> Int32 {
        guard args.count >= 3,
            let command = Command(rawValue: args[1].lowercased()),
            let scenario = Scenario(rawValue: args[2].lowercased())
        else {
            printUsage()
            return 2
        }

        do {
            let options = Array(args.dropFirst(3))
            switch command {
            case .prepare:
                let unknown = options.filter { $0 != "--no-sleep" }
                guard unknown.isEmpty else {
                    throw RunnerError.failed(
                        "unknown prepare option(s): \(unknown.joined(separator: ", "))")
                }
                let shouldSleep = !options.contains("--no-sleep")
                try prepare(scenario: scenario, shouldSleep: shouldSleep)
            case .verify:
                let unknown = options.filter { $0 != "--check-only" }
                guard unknown.isEmpty else {
                    throw RunnerError.failed(
                        "unknown verify option(s): \(unknown.joined(separator: ", "))")
                }
                let checkOnly = options.contains("--check-only")
                try verify(scenario: scenario, checkOnly: checkOnly)
            }
            return 0
        } catch {
            fputs("error: \(error)\n", stderr)
            return 1
        }
    }

    private func printUsage() {
        print(
            """
            Usage:
              swift run WakeCycleScenarios prepare <finder|app> [--no-sleep]
              swift run WakeCycleScenarios verify <finder|app> [--check-only]

            Notes:
              - Requires exactly two external displays and no built-in display.
              - Requires Accessibility permission.
              - prepare creates/positions real app windows and optionally puts the Mac to sleep.
              - verify defaults to: perturb one tracked window, restore tracked windows, then verify.
              - verify --check-only performs passive post-wake validation with no perturb/restore.
            """)
    }

    private var scenarioDirectory: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Stay/WakeCycleScenarios", isDirectory: true)
    }

    private func stateURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-state.json")
    }

    private func reportURL(for scenario: Scenario) -> URL {
        scenarioDirectory.appendingPathComponent("\(scenario.rawValue)-report.json")
    }

    private func prepare(scenario: Scenario, shouldSleep: Bool) throws {
        try ensurePrerequisites()
        let displays = try validatedExternalDisplays()
        let display1 = displays[0]
        let display2 = displays[1]

        let pid = try ensureAppRunning(bundleID: scenario.bundleID)
        let baselineWindows = liveWindows(pid: pid)

        let creation = try createScenarioWindows(scenario: scenario)

        guard runAppleScript(creation.script) else {
            throw RunnerError.scriptFailed("failed to create scenario windows")
        }

        let discovered = try waitForWindows(
            pid: pid,
            timeout: 20,
            condition: { windows in
                let newWindows = self.newWindows(current: windows, baseline: baselineWindows)
                let matching = self.matchingWindows(newWindows, titleHints: creation.titleHints)
                return matching.count >= 2
            }
        )

        let newWindows = newWindows(current: discovered, baseline: baselineWindows)
        let candidates = matchingWindows(newWindows, titleHints: creation.titleHints)
        guard candidates.count >= 2 else {
            throw RunnerError.failed("could not identify both newly created windows")
        }

        let titleOne = creation.titleHints[0]
        let titleTwo = creation.titleHints[1]

        guard
            let windowOne = bestWindow(matchingTitleHint: titleOne, in: candidates),
            let windowTwo = bestWindow(matchingTitleHint: titleTwo, in: candidates)
        else {
            throw RunnerError.failed("could not match windows by title hints")
        }

        let frameOne = scenarioFrame(on: display1.screen, offset: 0)
        let frameTwo = scenarioFrame(on: display2.screen, offset: 0)

        guard setWindowFrame(windowOne.element, frame: frameOne) else {
            throw RunnerError.failed("failed to place first window")
        }
        guard setWindowFrame(windowTwo.element, frame: frameTwo) else {
            throw RunnerError.failed("failed to place second window")
        }

        guard
            waitForDisplays(
                pid: pid, expected: [(titleOne, display1.id), (titleTwo, display2.id)], timeout: 10)
        else {
            throw RunnerError.failed("windows did not settle on target displays")
        }

        let state = ScenarioState(
            scenario: scenario.rawValue,
            bundleID: scenario.bundleID,
            preparedAt: Date(),
            trackedWindows: [
                TrackedWindow(
                    titleHint: titleOne,
                    expectedDisplayID: display1.id,
                    expectedFrame: CodableRect(frameOne)
                ),
                TrackedWindow(
                    titleHint: titleTwo,
                    expectedDisplayID: display2.id,
                    expectedFrame: CodableRect(frameTwo)
                ),
            ],
            createdPaths: creation.createdPaths
        )

        try persistState(state, to: stateURL(for: scenario))

        print("Prepared wake-cycle scenario '\(scenario.rawValue)' for \(scenario.appName).")
        print("State file: \(stateURL(for: scenario).path)")
        print("Window 1 (\(titleOne)) -> display \(display1.id)")
        print("Window 2 (\(titleTwo)) -> display \(display2.id)")

        if shouldSleep {
            print("Sleeping machine in 3 seconds. After wake/login, run:")
            print("  swift run WakeCycleScenarios verify \(scenario.rawValue)")
            Thread.sleep(forTimeInterval: 3)
            _ = runCommand("/usr/bin/pmset", ["sleepnow"])
        } else {
            print("Skipped sleep (--no-sleep). Manually sleep/wake, then run verify.")
        }
    }

    private func verify(scenario: Scenario, checkOnly: Bool) throws {
        try ensurePrerequisites()
        let displays = try validatedExternalDisplays()
        let state = try loadState(from: stateURL(for: scenario))

        guard state.bundleID == scenario.bundleID else {
            throw RunnerError.failed(
                "state bundle mismatch: expected \(scenario.bundleID), found \(state.bundleID)")
        }

        let requiredDisplays = Set(state.trackedWindows.map(\.expectedDisplayID))
        print("Waiting for displays to be online/awake: \(requiredDisplays.sorted())")
        guard waitForDisplayReadinessWithProgress(requiredDisplays, timeout: 45) else {
            throw RunnerError.failed("required displays not ready after wake")
        }

        let pid = try ensureAppRunning(bundleID: scenario.bundleID)
        print("Verifying scenario '\(scenario.rawValue)' for app pid=\(pid)")

        if checkOnly {
            print("Check-only mode enabled; skipping perturbation and restore.")
        } else {
            print("Perturbing one tracked window before restore.")
            let didPerturb = perturbOneWindowOffExpectedDisplay(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pid: pid,
                displays: displays
            )
            if didPerturb {
                sleepRunLoop(1.0)
            } else {
                print("No perturbation was applied; continuing to restore anyway.")
            }

            print("Applying restore attempts from saved scenario state.")
            _ = restoreTrackedWindowsWithProgress(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pid: pid,
                timeout: 20
            )
        }

        let passed = waitForVerificationWithProgress(
            scenario: scenario,
            trackedWindows: state.trackedWindows,
            pid: pid,
            timeout: 20
        )

        let details: [String]
        if passed {
            details = ["all tracked windows restored to expected displays"]
        } else {
            details = verificationMismatches(
                scenario: scenario,
                trackedWindows: state.trackedWindows,
                pid: pid
            )
        }

        let report = ScenarioReport(
            scenario: scenario.rawValue,
            verifiedAt: Date(),
            passed: passed,
            details: details
        )
        try persistReport(report, to: reportURL(for: scenario))

        if passed {
            print("PASS: wake-cycle scenario '\(scenario.rawValue)'")
        } else {
            print("FAIL: wake-cycle scenario '\(scenario.rawValue)'")
            details.forEach { print("  - \($0)") }
            throw RunnerError.failed("verification failed")
        }

        cleanupCreatedPaths(state.createdPaths)
        print("Report file: \(reportURL(for: scenario).path)")
    }

    private func ensurePrerequisites() throws {
        guard AXIsProcessTrusted() else {
            throw RunnerError.failed("Accessibility permission is required")
        }
        try fileManager.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
    }

    private func validatedExternalDisplays() throws -> [(screen: NSScreen, id: UInt32)] {
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

        var result: [(screen: NSScreen, id: UInt32)] = []
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

    private func createScenarioWindows(scenario: Scenario) throws -> (
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
        }
    }

    private func ensureAppRunning(bundleID: String) throws -> Int32 {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier == bundleID
        }) {
            _ = running.activate()
            return running.processIdentifier
        }

        guard runAppleScript("tell application id \"\(bundleID)\" to activate") else {
            throw RunnerError.failed("could not launch app \(bundleID)")
        }

        guard let pid = waitForPID(bundleID: bundleID, timeout: 10) else {
            throw RunnerError.failed("app \(bundleID) did not launch in time")
        }
        return pid
    }

    private func waitForPID(bundleID: String, timeout: TimeInterval) -> Int32? {
        var pid: Int32?
        _ = waitUntil(timeout: timeout) {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                !$0.isTerminated && $0.bundleIdentifier == bundleID
            }) {
                pid = running.processIdentifier
                return true
            }
            return false
        }
        return pid
    }

    private func liveWindows(pid: Int32) -> [LiveWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else {
            return []
        }

        return windows.compactMap { element in
            guard isFrameSettable(element), let frame = frameForWindow(element) else {
                return nil
            }

            let title = stringValue(of: element, attribute: kAXTitleAttribute as CFString)
            let role = stringValue(of: element, attribute: kAXRoleAttribute as CFString)
            let subrole = stringValue(of: element, attribute: kAXSubroleAttribute as CFString)

            if normalized(title) == "desktop" {
                return nil
            }

            return LiveWindow(
                element: element, title: title, role: role, subrole: subrole, frame: frame)
        }
    }

    private func newWindows(current: [LiveWindow], baseline: [LiveWindow]) -> [LiveWindow] {
        current.filter { currentWindow in
            !baseline.contains(where: { baselineWindow in
                CFEqual(currentWindow.element, baselineWindow.element)
            })
        }
    }

    private func matchingWindows(_ windows: [LiveWindow], titleHints: [String]) -> [LiveWindow] {
        windows.filter { window in
            guard let title = normalized(window.title) else {
                return false
            }
            return titleHints.contains(where: { title.contains($0) })
        }
    }

    private func bestWindow(matchingTitleHint hint: String, in windows: [LiveWindow]) -> LiveWindow?
    {
        windows.first(where: { normalized($0.title)?.contains(hint) == true })
    }

    private func waitForWindows(
        pid: Int32,
        timeout: TimeInterval,
        condition: ([LiveWindow]) -> Bool
    ) throws -> [LiveWindow] {
        var result: [LiveWindow] = []
        let satisfied = waitUntil(timeout: timeout) {
            let current = liveWindows(pid: pid)
            if condition(current) {
                result = current
                return true
            }
            return false
        }
        if !satisfied {
            throw RunnerError.failed("timed out waiting for windows")
        }
        return result
    }

    private func scenarioFrame(on screen: NSScreen, offset: Int) -> CGRect {
        let visible = screen.visibleFrame
        let width = min(max(460, visible.width * 0.5), visible.width - 90)
        let height = min(max(340, visible.height * 0.58), visible.height - 110)
        let x = visible.minX + 50 + (CGFloat(offset) * 35)
        let y = visible.minY + 70 + (CGFloat(offset) * 25)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard
            let position = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue)
        if positionResult == .success && sizeResult == .success {
            return true
        }

        var mutableFrame = frame
        if let frameValue = AXValueCreate(.cgRect, &mutableFrame) {
            let frameResult = AXUIElementSetAttributeValue(
                window, "AXFrame" as CFString, frameValue)
            if frameResult == .success {
                return true
            }
        }

        return false
    }

    private func isFrameSettable(_ window: AXUIElement) -> Bool {
        var positionSettable = DarwinBoolean(false)
        let positionResult = AXUIElementIsAttributeSettable(
            window, kAXPositionAttribute as CFString, &positionSettable
        )
        guard positionResult == .success, positionSettable.boolValue else {
            return false
        }

        var sizeSettable = DarwinBoolean(false)
        let sizeResult = AXUIElementIsAttributeSettable(
            window, kAXSizeAttribute as CFString, &sizeSettable
        )
        return sizeResult == .success && sizeSettable.boolValue
    }

    private func frameForWindow(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
                == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
                == .success,
            let positionRef = positionValue,
            let sizeRef = sizeValue,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }

        let positionAX = unsafeDowncast(positionRef as AnyObject, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeRef as AnyObject, to: AXValue.self)

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &origin),
            AXValueGetValue(sizeAX, .cgSize, &size)
        else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func stringValue(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func displayID(for screen: NSScreen) -> UInt32? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else {
            return nil
        }
        return number.uint32Value
    }

    private func displayID(for frame: CGRect) -> UInt32? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return nil
        }

        let scored = screens.map { screen in
            (screen: screen, area: frame.intersection(screen.frame).area)
        }

        if let best = scored.max(by: { $0.area < $1.area }), best.area > 0 {
            return displayID(for: best.screen)
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let nearest = screens.min { lhs, rhs in
            distanceSquared(center, lhs.frame.center) < distanceSquared(center, rhs.frame.center)
        }
        return nearest.flatMap(displayID(for:))
    }

    private func verifyTrackedWindows(
        scenario: Scenario,
        _ trackedWindows: [TrackedWindow],
        pid: Int32
    ) -> Bool {
        let windows = liveWindows(pid: pid)
        guard !windows.isEmpty else {
            return false
        }

        for tracked in trackedWindows {
            guard let matched = bestWindowForTracked(tracked, windows: windows) else {
                return false
            }
            if !isAligned(scenario: scenario, tracked: tracked, live: matched) {
                return false
            }
        }

        return true
    }

    private func verificationMismatches(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pid: Int32
    ) -> [String] {
        let windows = liveWindows(pid: pid)
        if windows.isEmpty {
            return ["no live windows exposed for app pid=\(pid)"]
        }

        var issues: [String] = []
        for tracked in trackedWindows {
            guard let matched = bestWindowForTracked(tracked, windows: windows) else {
                issues.append("missing window for title hint '\(tracked.titleHint)'")
                continue
            }
            guard let currentDisplay = displayID(for: matched.frame) else {
                issues.append("could not infer display for title hint '\(tracked.titleHint)'")
                continue
            }
            if !isAligned(scenario: scenario, tracked: tracked, live: matched) {
                let expected = tracked.expectedFrame.cgRect
                issues.append(
                    "window '\(tracked.titleHint)' on display \(currentDisplay) frame \(frameSummary(matched.frame)); expected display \(tracked.expectedDisplayID) frame \(frameSummary(expected))"
                )
            }
        }

        return issues
    }

    private func bestWindowForTracked(_ tracked: TrackedWindow, windows: [LiveWindow])
        -> LiveWindow?
    {
        let titleHint = tracked.titleHint

        let byTitle = windows.first { window in
            normalized(window.title)?.contains(titleHint) == true
        }
        if let byTitle {
            return byTitle
        }

        let expectedFrame = tracked.expectedFrame.cgRect
        return windows.min { lhs, rhs in
            frameDistance(lhs.frame, expectedFrame) < frameDistance(rhs.frame, expectedFrame)
        }
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    private func waitForDisplays(
        pid: Int32,
        expected: [(titleHint: String, displayID: UInt32)],
        timeout: TimeInterval
    ) -> Bool {
        waitUntil(timeout: timeout) {
            let windows = self.liveWindows(pid: pid)
            for expectation in expected {
                guard
                    let matched = windows.first(where: {
                        self.normalized($0.title)?.contains(expectation.titleHint) == true
                    }),
                    let currentDisplay = self.displayID(for: matched.frame),
                    currentDisplay == expectation.displayID
                else {
                    return false
                }
            }
            return true
        }
    }

    private func waitForDisplayReadiness(_ requiredDisplays: Set<UInt32>, timeout: TimeInterval)
        -> Bool
    {
        waitUntil(timeout: timeout) {
            let online = self.onlineDisplays()
            for display in requiredDisplays {
                guard online.contains(display) else {
                    return false
                }
                if CGDisplayIsAsleep(display) != 0 {
                    return false
                }
            }
            return true
        }
    }

    private func waitForDisplayReadinessWithProgress(
        _ requiredDisplays: Set<UInt32>,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date.distantPast
        while Date() < deadline {
            let online = onlineDisplays()
            let missing = requiredDisplays.filter { !online.contains($0) }.sorted()
            let asleep =
                requiredDisplays
                .filter { online.contains($0) && CGDisplayIsAsleep($0) != 0 }
                .sorted()

            if missing.isEmpty && asleep.isEmpty {
                print("Display readiness OK.")
                return true
            }

            if Date() >= nextLog {
                print("Display readiness pending: missing=\(missing) asleep=\(asleep)")
                nextLog = Date().addingTimeInterval(1.0)
            }

            sleepRunLoop(0.2)
        }

        return waitForDisplayReadiness(requiredDisplays, timeout: 0.1)
    }

    private func waitForVerificationWithProgress(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pid: Int32,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var nextLog = Date.distantPast

        while Date() < deadline {
            let mismatches = verificationMismatches(
                scenario: scenario,
                trackedWindows: trackedWindows,
                pid: pid
            )
            if mismatches.isEmpty {
                print("Verification passed.")
                return true
            }

            if Date() >= nextLog {
                print("Verification pending (\(mismatches.count) mismatch(es)):")
                mismatches.forEach { print("  - \($0)") }
                nextLog = Date().addingTimeInterval(1.0)
            }

            sleepRunLoop(0.2)
        }

        return verifyTrackedWindows(scenario: scenario, trackedWindows, pid: pid)
    }

    private func restoreTrackedWindowsWithProgress(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pid: Int32,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            let mismatches = verificationMismatches(
                scenario: scenario,
                trackedWindows: trackedWindows,
                pid: pid
            )
            if mismatches.isEmpty {
                print("Restore converged before timeout.")
                return true
            }

            attempt += 1
            print("Restore attempt \(attempt) (\(mismatches.count) mismatch(es))")

            let result = applyTrackedFrames(
                scenario: scenario, trackedWindows: trackedWindows, pid: pid)
            print(
                "  moved=\(result.moved) aligned=\(result.aligned) failures=\(result.failures) unmatched=\(result.unmatched)"
            )

            if result.failures > 0 || result.unmatched > 0 {
                let latest = verificationMismatches(
                    scenario: scenario,
                    trackedWindows: trackedWindows,
                    pid: pid
                )
                latest.forEach { print("  - \($0)") }
            }

            sleepRunLoop(1.0)
        }

        return verifyTrackedWindows(scenario: scenario, trackedWindows, pid: pid)
    }

    private func applyTrackedFrames(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pid: Int32
    ) -> (moved: Int, aligned: Int, failures: Int, unmatched: Int) {
        let windows = liveWindows(pid: pid)
        let assignments = assignLiveWindows(trackedWindows, to: windows)
        var moved = 0
        var aligned = 0
        var failures = 0

        for (tracked, live) in assignments {
            guard displayID(for: live.frame) != nil else {
                failures += 1
                continue
            }

            if isAligned(scenario: scenario, tracked: tracked, live: live) {
                aligned += 1
                continue
            }

            let targetFrame = restoreFrame(for: scenario, tracked: tracked, live: live)
            if setWindowFrame(live.element, frame: targetFrame) {
                sleepRunLoop(0.2)
                if isAligned(scenario: scenario, tracked: tracked, element: live.element) {
                    moved += 1
                } else if setWindowFrame(live.element, frame: targetFrame) {
                    sleepRunLoop(0.2)
                    if isAligned(scenario: scenario, tracked: tracked, element: live.element) {
                        moved += 1
                    } else {
                        failures += 1
                    }
                } else {
                    failures += 1
                }
            } else {
                failures += 1
            }
        }

        return (
            moved: moved,
            aligned: aligned,
            failures: failures,
            unmatched: max(0, trackedWindows.count - assignments.count)
        )
    }

    private func perturbOneWindowOffExpectedDisplay(
        scenario: Scenario,
        trackedWindows: [TrackedWindow],
        pid: Int32,
        displays: [(screen: NSScreen, id: UInt32)]
    ) -> Bool {
        let windows = liveWindows(pid: pid)
        let assignments = assignLiveWindows(trackedWindows, to: windows)
        guard let chosen = assignments.first else {
            return false
        }

        guard let targetDisplay = displays.first(where: { $0.id != chosen.0.expectedDisplayID })
        else {
            return false
        }

        let frame = perturbationFrame(for: scenario, live: chosen.1, on: targetDisplay.screen)
        let moved = setWindowFrame(chosen.1.element, frame: frame)
        if moved {
            print(
                "Perturbed '\(chosen.0.titleHint)' to display \(targetDisplay.id) before verification."
            )
        }
        return moved
    }

    private func assignLiveWindows(
        _ trackedWindows: [TrackedWindow],
        to liveWindows: [LiveWindow]
    ) -> [(TrackedWindow, LiveWindow)] {
        var available = Array(liveWindows.indices)
        var assignments: [(TrackedWindow, LiveWindow)] = []

        for tracked in trackedWindows {
            guard !available.isEmpty else {
                break
            }

            guard
                let selectedIndex = bestCandidateIndex(
                    for: tracked, windows: liveWindows, candidates: available)
            else {
                continue
            }

            assignments.append((tracked, liveWindows[selectedIndex]))
            available.removeAll { $0 == selectedIndex }
        }

        return assignments
    }

    private func bestCandidateIndex(
        for tracked: TrackedWindow,
        windows: [LiveWindow],
        candidates: [Int]
    ) -> Int? {
        guard !candidates.isEmpty else {
            return nil
        }

        let titleMatches = candidates.filter { index in
            normalized(windows[index].title)?.contains(tracked.titleHint) == true
        }

        let pool = titleMatches.isEmpty ? candidates : titleMatches
        let expectedFrame = tracked.expectedFrame.cgRect
        return pool.min { lhs, rhs in
            frameDistance(windows[lhs].frame, expectedFrame)
                < frameDistance(windows[rhs].frame, expectedFrame)
        }
    }

    private func restoreFrame(for scenario: Scenario, tracked: TrackedWindow, live: LiveWindow)
        -> CGRect
    {
        _ = scenario
        _ = live
        return tracked.expectedFrame.cgRect
    }

    private func perturbationFrame(for scenario: Scenario, live: LiveWindow, on screen: NSScreen)
        -> CGRect
    {
        let base = scenarioFrame(on: screen, offset: 2)
        if scenario == .finder {
            return CGRect(
                x: base.minX,
                y: base.minY,
                width: live.frame.width,
                height: live.frame.height
            )
        }
        return base
    }

    private func isAligned(scenario: Scenario, tracked: TrackedWindow, live: LiveWindow) -> Bool {
        guard let currentDisplay = displayID(for: live.frame) else {
            return false
        }
        return isAligned(
            scenario: scenario,
            tracked: tracked,
            currentDisplay: currentDisplay,
            frame: live.frame
        )
    }

    private func isAligned(scenario: Scenario, tracked: TrackedWindow, element: AXUIElement) -> Bool
    {
        guard let frame = frameForWindow(element), let currentDisplay = displayID(for: frame) else {
            return false
        }
        return isAligned(
            scenario: scenario,
            tracked: tracked,
            currentDisplay: currentDisplay,
            frame: frame
        )
    }

    private func isAligned(
        scenario: Scenario,
        tracked: TrackedWindow,
        currentDisplay: UInt32,
        frame: CGRect
    ) -> Bool {
        guard currentDisplay == tracked.expectedDisplayID else {
            return false
        }

        let expected = tracked.expectedFrame.cgRect
        let tolerance = frameTolerance(scenario: scenario)
        let positionDelta = max(abs(frame.minX - expected.minX), abs(frame.minY - expected.minY))
        let sizeDelta = max(abs(frame.width - expected.width), abs(frame.height - expected.height))
        return positionDelta <= tolerance.position && sizeDelta <= tolerance.size
    }

    private func frameTolerance(scenario: Scenario) -> (position: CGFloat, size: CGFloat) {
        switch scenario {
        case .finder:
            // Finder can snap by a few points after cross-display moves.
            return (position: 8, size: 12)
        case .app:
            return (position: 4, size: 6)
        }
    }

    private func frameSummary(_ frame: CGRect) -> String {
        String(
            format: "(x=%.1f y=%.1f w=%.1f h=%.1f)",
            frame.minX, frame.minY, frame.width, frame.height
        )
    }

    private func onlineDisplays() -> Set<UInt32> {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return Set(displays.prefix(Int(count)))
    }

    private func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.1, condition: () -> Bool)
        -> Bool
    {
        if condition() {
            return true
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(poll))
            if condition() {
                return true
            }
        }

        return condition()
    }

    private func sleepRunLoop(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func persistState(_ state: ScenarioState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func loadState(from url: URL) throws -> ScenarioState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScenarioState.self, from: data)
    }

    private func persistReport(_ report: ScenarioReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private func cleanupCreatedPaths(_ paths: [String]) {
        for path in paths {
            try? fileManager.removeItem(atPath: path)
        }
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else {
            return false
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    @discardableResult
    private func runCommand(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            return nil
        }
        return value.lowercased()
    }
}

enum RunnerError: Error, LocalizedError {
    case failed(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message), .scriptFailed(let message):
            return message
        }
    }
}

extension CGRect {
    fileprivate var area: CGFloat {
        guard !isNull, width > 0, height > 0 else {
            return 0
        }
        return width * height
    }

    fileprivate var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}

@main
struct Main {
    static func main() {
        var runner = WakeCycleScenarioRunner()
        exit(runner.run())
    }
}
