import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import StayCore

// Design goal: capture enough stable metadata to restore windows predictably
// after wake, while tolerating title/index drift between capture and restore.
final class AXWindowSnapshotService: WindowSnapshotCapturing, WindowSnapshotRestoring {
    private let logger = Logger(subsystem: "com.stay.app", category: "AXWindowSnapshotService")
    private let workspace: NSWorkspace
    private let screenService: ScreenCoordinateServicing

    init(
        workspace: NSWorkspace = .shared,
        screenService: ScreenCoordinateServicing
    ) {
        self.workspace = workspace
        self.screenService = screenService
    }

    func capture() -> [WindowSnapshot] {
        guard AccessibilityPermission.isTrusted(prompt: false) else {
            logger.warning("Capture skipped because Accessibility permission is unavailable")
            return []
        }

        let applications = workspace.runningApplications
            .filter { shouldInspect($0) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        let onScreenWindowServerWindowsByPID = windowServerWindowsByPID(options: [
            .optionOnScreenOnly
        ])
        var allWindowServerWindowsByPID: [Int32: [WindowServerWindow]]?

        var snapshots: [WindowSnapshot] = []

        for app in applications {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let windows = windowsForAppElement(appElement)
            var appSnapshots: [WindowSnapshot] = []
            appSnapshots.reserveCapacity(windows.count)

            for (index, window) in windows.enumerated() {
                guard !isWindowMinimized(window), let frame = frameForWindow(window) else {
                    continue
                }

                guard frame.width > 1, frame.height > 1 else {
                    continue
                }

                let displayID = screenService.displayID(for: frame)
                if displayID == nil {
                    logger.debug(
                        "Captured window without display ID (pid=\(app.processIdentifier, privacy: .public) title=\(String(describing: self.stringValue(of: window, attribute: kAXTitleAttribute as CFString)), privacy: .public))"
                    )
                }

                let snapshot = WindowSnapshot(
                    appPID: app.processIdentifier,
                    appBundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? "Unknown",
                    windowTitle: stringValue(of: window, attribute: kAXTitleAttribute as CFString),
                    windowIndex: index,
                    frame: CodableRect(frame),
                    screenDisplayID: displayID
                )

                appSnapshots.append(snapshot)
            }

            var fallbackWindows = onScreenWindowServerWindowsByPID[app.processIdentifier] ?? []
            var fallbackSource = "on-screen"

            if fallbackWindows.count <= appSnapshots.count {
                if allWindowServerWindowsByPID == nil {
                    allWindowServerWindowsByPID = windowServerWindowsByPID(options: [.optionAll])
                }

                let fullListFallbackWindows =
                    allWindowServerWindowsByPID?[app.processIdentifier] ?? []
                let preferredFullListFallback = preferredOffScreenFallbackWindows(
                    from: fullListFallbackWindows
                )
                if preferredFullListFallback.count > fallbackWindows.count {
                    fallbackWindows = preferredFullListFallback
                    fallbackSource = "all-window-list"
                }
            }

            let hasLayeredFallbackWindows = fallbackWindows.contains(where: { $0.layer > 0 })
            let hasAllWindowListCountAdvantage =
                fallbackSource == "all-window-list" && fallbackWindows.count > appSnapshots.count
            let shouldMergeFallbackWindows =
                appSnapshots.isEmpty || hasLayeredFallbackWindows || hasAllWindowListCountAdvantage

            if !fallbackWindows.isEmpty, shouldMergeFallbackWindows {
                var knownFrameKeys = Set(appSnapshots.map(snapshotFrameIdentityKey))
                var appendedFallbackCount = 0

                for fallbackWindow in fallbackWindows {
                    let fallbackFrameKey = Self.frameIdentityKey(frame: fallbackWindow.frame)
                    guard !knownFrameKeys.contains(fallbackFrameKey) else {
                        continue
                    }

                    knownFrameKeys.insert(fallbackFrameKey)
                    let displayID = screenService.displayID(for: fallbackWindow.frame)
                    let snapshot = WindowSnapshot(
                        appPID: app.processIdentifier,
                        appBundleID: app.bundleIdentifier,
                        appName: app.localizedName ?? "Unknown",
                        windowTitle: fallbackWindow.title,
                        windowIndex: appSnapshots.count,
                        frame: CodableRect(fallbackWindow.frame),
                        screenDisplayID: displayID
                    )
                    appSnapshots.append(snapshot)
                    appendedFallbackCount += 1
                }

                if appSnapshots.isEmpty {
                    logger.debug(
                        "AX capture empty for pid=\(app.processIdentifier, privacy: .public); WindowServer \(fallbackSource, privacy: .public) fallback had no unique windows"
                    )
                } else if appendedFallbackCount > 0 && windows.isEmpty {
                    logger.debug(
                        "AX capture empty for pid=\(app.processIdentifier, privacy: .public); using WindowServer \(fallbackSource, privacy: .public) fallback count=\(fallbackWindows.count, privacy: .public)"
                    )
                } else if appendedFallbackCount > 0 {
                    logger.debug(
                        "AX capture partial for pid=\(app.processIdentifier, privacy: .public); merged \(appendedFallbackCount, privacy: .public) WindowServer \(fallbackSource, privacy: .public) window(s)"
                    )
                }
            } else if !fallbackWindows.isEmpty, !appSnapshots.isEmpty {
                logger.debug(
                    "Skipped WindowServer fallback merge for pid=\(app.processIdentifier, privacy: .public) because AX already captured windows and fallback did not add expected extra windows (source=\(fallbackSource, privacy: .public) fallbackCount=\(fallbackWindows.count, privacy: .public) axCount=\(appSnapshots.count, privacy: .public))"
                )
            }

            snapshots.append(contentsOf: appSnapshots)
            let capturedForApp = appSnapshots.count
            if capturedForApp > 0 {
                logger.debug(
                    "Captured \(capturedForApp, privacy: .public) snapshot(s) for app=\(app.localizedName ?? "Unknown", privacy: .public) pid=\(app.processIdentifier, privacy: .public)"
                )
            } else {
                logger.debug(
                    "Captured 0 snapshot(s) for app=\(app.localizedName ?? "Unknown", privacy: .public) pid=\(app.processIdentifier, privacy: .public)"
                )
            }
        }

        logger.info(
            "Capture produced \(snapshots.count, privacy: .public) snapshot(s) across \(applications.count, privacy: .public) app(s)"
        )
        return snapshots
    }

    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult {
        guard AccessibilityPermission.isTrusted(prompt: false), !snapshots.isEmpty else {
            logger.warning(
                "Restore skipped (permission=\(AccessibilityPermission.isTrusted(prompt: false), privacy: .public) snapshots=\(snapshots.count, privacy: .public))"
            )
            return WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 0,
                recoverableFailureCount: max(1, snapshots.count)
            )
        }

        // Group by process to avoid cross-app window matching.
        let grouped = groupedSnapshotsByTargetPID(snapshots)
        // Coordinator treats this as a success signal for ending post-wake retries.
        var movedWindowCount = 0
        var alreadyAlignedCount = 0
        var recoverableFailureCount = 0
        // "Deferred" snapshots are windows we intentionally skip this attempt
        // because AX has not exposed enough windows for a safe restore yet.
        var deferredSnapshotCount = 0
        var resolvedSnapshots: [WindowSnapshot] = []
        logger.info(
            "Starting restore for \(snapshots.count, privacy: .public) snapshot(s) across \(grouped.count, privacy: .public) app(s)"
        )
        let originalFrontmostPID = workspace.frontmostApplication?.processIdentifier
        var activatedPIDsForWindowExposure = Set<Int32>()

        for (appPID, appSnapshots) in grouped {
            let appElement = AXUIElementCreateApplication(appPID)
            var windows = windowsForAppElement(appElement)
            let requiresFullExposure = appSnapshots.count > 1 && windows.count < appSnapshots.count
            if windows.isEmpty || requiresFullExposure,
                isAppRunning(pid: appPID),
                appPID != originalFrontmostPID,
                activateAppForWindowExposure(pid: appPID)
            {
                activatedPIDsForWindowExposure.insert(appPID)
                logger.debug(
                    "Activated app pid=\(appPID, privacy: .public) to expose AX windows for restore"
                )
                let minimumExpectedWindowCount =
                    requiresFullExposure
                    ? appSnapshots.count
                    : max(1, windows.count)
                windows = waitForWindowExposure(
                    appElement: appElement,
                    minimumCount: minimumExpectedWindowCount
                )
            }

            if appSnapshots.count > 1, windows.count < appSnapshots.count {
                recoverableFailureCount += appSnapshots.count
                deferredSnapshotCount += appSnapshots.count
                logger.warning(
                    "App pid=\(appPID, privacy: .public) exposed \(windows.count, privacy: .public)/\(appSnapshots.count, privacy: .public) expected windows; deferring app restore"
                )
                continue
            }

            guard !windows.isEmpty else {
                if isAppRunning(pid: appPID) {
                    recoverableFailureCount += appSnapshots.count
                    deferredSnapshotCount += appSnapshots.count
                    logger.warning(
                        "App pid=\(appPID, privacy: .public) is running but has no AX windows yet; deferring \(appSnapshots.count, privacy: .public) snapshot(s)"
                    )
                }
                logger.debug(
                    "No AX windows available for pid=\(appPID, privacy: .public) during restore"
                )
                continue
            }

            logger.debug(
                "Restore app pid=\(appPID, privacy: .public) snapshots=\(appSnapshots.count, privacy: .public) liveWindows=\(windows.count, privacy: .public)"
            )
            let candidates = windows.map { window in
                WindowCandidate(
                    title: stringValue(of: window, attribute: kAXTitleAttribute as CFString),
                    frame: frameForWindow(window)
                )
            }
            var unusedIndices = Set(windows.indices)

            for snapshot in appSnapshots.sorted(by: { $0.windowIndex < $1.windowIndex }) {
                guard
                    let windowIndex = bestMatchingIndex(
                        for: snapshot,
                        candidates: candidates,
                        unusedIndices: unusedIndices
                    )
                else {
                    recoverableFailureCount += 1
                    logger.debug(
                        "Could not match snapshot window for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) index=\(snapshot.windowIndex, privacy: .public)"
                    )
                    continue
                }

                unusedIndices.remove(windowIndex)
                let adjustedFrame = screenService.adjustedFrame(
                    snapshot.frame.cgRect,
                    preferredDisplayID: snapshot.screenDisplayID
                )
                if let currentFrame = frameForWindow(windows[windowIndex]),
                    isApproximatelySameFrame(currentFrame, adjustedFrame)
                {
                    alreadyAlignedCount += 1
                    resolvedSnapshots.append(snapshot)
                    continue
                }
                let setFrameResult = setFrame(adjustedFrame, for: windows[windowIndex])
                if setFrameResult.success {
                    // Some apps report AX success but immediately snap windows back.
                    // Count a move only after the frame actually converges.
                    if didFrameConverge(for: windows[windowIndex], expectedFrame: adjustedFrame) {
                        movedWindowCount += 1
                        resolvedSnapshots.append(snapshot)
                    } else {
                        recoverableFailureCount += 1
                        logger.warning(
                            "AX setFrame reported success but frame did not converge for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) index=\(windowIndex, privacy: .public)"
                        )
                    }
                } else {
                    if isRecoverableAXError(setFrameResult.position)
                        || isRecoverableAXError(setFrameResult.size)
                    {
                        recoverableFailureCount += 1
                    }
                    logger.warning(
                        "AX setFrame failed for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) index=\(windowIndex, privacy: .public) positionError=\(setFrameResult.position.rawValue, privacy: .public) sizeError=\(setFrameResult.size.rawValue, privacy: .public)"
                    )
                }
            }
        }

        restoreFrontmostApplicationIfNeeded(
            originalFrontmostPID: originalFrontmostPID,
            activatedPIDsForWindowExposure: activatedPIDsForWindowExposure
        )

        logger.info(
            "Restore finished with movedWindowCount=\(movedWindowCount, privacy: .public) alreadyAlignedCount=\(alreadyAlignedCount, privacy: .public) recoverableFailureCount=\(recoverableFailureCount, privacy: .public) deferredSnapshotCount=\(deferredSnapshotCount, privacy: .public)"
        )
        return WindowRestoreResult(
            isComplete: recoverableFailureCount == 0,
            movedWindowCount: movedWindowCount,
            alreadyAlignedCount: alreadyAlignedCount,
            recoverableFailureCount: recoverableFailureCount,
            deferredSnapshotCount: deferredSnapshotCount,
            resolvedSnapshots: resolvedSnapshots
        )
    }

    private func shouldInspect(_ application: NSRunningApplication) -> Bool {
        guard !application.isTerminated else {
            return false
        }

        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }

        if application.activationPolicy != .regular {
            return false
        }

        return true
    }

    private func windowsForAppElement(_ appElement: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        if let value = copyAttributeValue(
            element: appElement, attribute: kAXWindowsAttribute as CFString),
            let windows = value as? [AXUIElement]
        {
            for window in windows {
                appendUnique(window, to: &candidates)
            }
        }

        if candidates.isEmpty {
            if let focusedWindow = axElement(
                of: appElement, attribute: kAXFocusedWindowAttribute as CFString)
            {
                appendUnique(focusedWindow, to: &candidates)
            }

            let discovered = discoverWindowLikeChildren(from: appElement, maxDepth: 3)
            for element in discovered {
                appendUnique(element, to: &candidates)
            }
        }

        return candidates
    }

    private func frameForWindow(_ window: AXUIElement) -> CGRect? {
        guard
            let positionValue = axValue(of: window, attribute: kAXPositionAttribute as CFString),
            let sizeValue = axValue(of: window, attribute: kAXSizeAttribute as CFString)
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetType(positionValue) == .cgPoint else {
            return nil
        }

        guard AXValueGetType(sizeValue) == .cgSize else {
            return nil
        }

        guard AXValueGetValue(positionValue, .cgPoint, &origin) else {
            return nil
        }

        guard AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func isWindowMinimized(_ window: AXUIElement) -> Bool {
        guard
            let value = copyAttributeValue(
                element: window, attribute: kAXMinimizedAttribute as CFString)
        else {
            return false
        }

        return (value as? Bool) ?? false
    }

    private func setFrame(_ frame: CGRect, for window: AXUIElement) -> SetFrameResult {
        var origin = frame.origin
        var size = frame.size

        guard
            let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return SetFrameResult(position: .failure, size: .failure)
        }

        let positionResult = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue
        )
        let sizeResult = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue
        )

        return SetFrameResult(position: positionResult, size: sizeResult)
    }

    private func didFrameConverge(for window: AXUIElement, expectedFrame: CGRect) -> Bool {
        if let frame = frameForWindow(window),
            isApproximatelySameFrame(frame, expectedFrame)
        {
            return true
        }

        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            if let frame = frameForWindow(window),
                isApproximatelySameFrame(frame, expectedFrame)
            {
                return true
            }
        }

        return false
    }

    private func stringValue(of element: AXUIElement, attribute: CFString) -> String? {
        guard let value = copyAttributeValue(element: element, attribute: attribute) else {
            return nil
        }

        return value as? String
    }

    private func copyAttributeValue(element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value
    }

    private func axValue(of element: AXUIElement, attribute: CFString) -> AXValue? {
        guard let value = copyAttributeValue(element: element, attribute: attribute) else {
            return nil
        }

        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value as AnyObject, to: AXValue.self)
    }

    private func axElement(of element: AXUIElement, attribute: CFString) -> AXUIElement? {
        guard let value = copyAttributeValue(element: element, attribute: attribute) else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
    }

    private func bestMatchingIndex(
        for snapshot: WindowSnapshot,
        candidates: [WindowCandidate],
        unusedIndices: Set<Int>
    ) -> Int? {
        if let snapshotTitle = snapshot.windowTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines), !snapshotTitle.isEmpty
        {
            let normalizedTitle = snapshotTitle.lowercased()
            for index in unusedIndices.sorted() {
                if candidates[index].title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    == normalizedTitle
                {
                    return index
                }
            }
        }

        if let closestByFrame = bestFrameMatchIndex(
            snapshot: snapshot,
            candidates: candidates,
            unusedIndices: unusedIndices
        ) {
            return closestByFrame
        }

        if snapshot.windowIndex >= 0, snapshot.windowIndex < candidates.count,
            unusedIndices.contains(snapshot.windowIndex)
        {
            return snapshot.windowIndex
        }

        return unusedIndices.sorted().first
    }

    private func bestFrameMatchIndex(
        snapshot: WindowSnapshot,
        candidates: [WindowCandidate],
        unusedIndices: Set<Int>
    ) -> Int? {
        let snapshotFrame = snapshot.frame.cgRect
        var bestIndex: Int?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for index in unusedIndices {
            guard let candidateFrame = candidates[index].frame else {
                continue
            }

            let score = frameDistanceScore(snapshotFrame, candidateFrame)
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func frameDistanceScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let originDelta = abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        let sizeDelta = abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
        return originDelta + (sizeDelta * 2)
    }

    private func isApproximatelySameFrame(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 2
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func isAppRunning(pid: Int32) -> Bool {
        workspace.runningApplications.contains { $0.processIdentifier == pid && !$0.isTerminated }
    }

    private func groupedSnapshotsByTargetPID(_ snapshots: [WindowSnapshot]) -> [Int32:
        [WindowSnapshot]]
    {
        let runningApps = workspace.runningApplications.filter { !$0.isTerminated }
        var grouped: [Int32: [WindowSnapshot]] = [:]

        for snapshot in snapshots {
            guard let targetPID = targetPID(for: snapshot, runningApps: runningApps) else {
                logger.debug(
                    "Skipping snapshot with no running target app (bundleID=\(String(describing: snapshot.appBundleID), privacy: .public) originalPID=\(snapshot.appPID, privacy: .public))"
                )
                continue
            }

            grouped[targetPID, default: []].append(snapshot)
        }

        return grouped
    }

    private func targetPID(for snapshot: WindowSnapshot, runningApps: [NSRunningApplication])
        -> Int32?
    {
        if let exactPIDMatch = runningApps.first(where: { $0.processIdentifier == snapshot.appPID })
        {
            return exactPIDMatch.processIdentifier
        }

        // PID can change after app relaunch, so fall back to stable identifiers.
        if let bundleID = snapshot.appBundleID,
            let bundleMatch = runningApps.first(where: { $0.bundleIdentifier == bundleID })
        {
            logger.debug(
                "Remapped snapshot bundleID=\(bundleID, privacy: .public) from pid=\(snapshot.appPID, privacy: .public) to pid=\(bundleMatch.processIdentifier, privacy: .public)"
            )
            return bundleMatch.processIdentifier
        }

        if let nameMatch = runningApps.first(where: { ($0.localizedName ?? "") == snapshot.appName }
        ) {
            logger.debug(
                "Remapped snapshot appName=\(snapshot.appName, privacy: .public) from pid=\(snapshot.appPID, privacy: .public) to pid=\(nameMatch.processIdentifier, privacy: .public)"
            )
            return nameMatch.processIdentifier
        }

        return nil
    }

    private func isRecoverableAXError(_ error: AXError) -> Bool {
        switch error {
        case .success:
            return false
        case .cannotComplete, .attributeUnsupported, .apiDisabled, .noValue, .failure:
            return true
        default:
            return false
        }
    }

    private func waitForWindowExposure(appElement: AXUIElement, minimumCount: Int) -> [AXUIElement]
    {
        var best = windowsForAppElement(appElement)
        guard best.count < minimumCount else {
            return best
        }

        let deadline = Date().addingTimeInterval(0.35)
        while best.count < minimumCount, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let current = windowsForAppElement(appElement)
            if current.count > best.count {
                best = current
            }
        }

        return best
    }

    private func activateAppForWindowExposure(pid: Int32) -> Bool {
        guard
            let app = workspace.runningApplications.first(where: {
                $0.processIdentifier == pid && !$0.isTerminated
            })
        else {
            return false
        }

        return app.activate()
    }

    private func restoreFrontmostApplicationIfNeeded(
        originalFrontmostPID: Int32?,
        activatedPIDsForWindowExposure: Set<Int32>
    ) {
        guard let originalFrontmostPID else {
            return
        }

        guard activatedPIDsForWindowExposure.contains(where: { $0 != originalFrontmostPID }) else {
            return
        }

        guard
            let originalFrontmostApp = workspace.runningApplications.first(where: {
                $0.processIdentifier == originalFrontmostPID && !$0.isTerminated
            })
        else {
            return
        }

        if originalFrontmostApp.activate() {
            logger.debug(
                "Re-activated original frontmost app pid=\(originalFrontmostPID, privacy: .public) after restore"
            )
        }
    }

    private func windowServerWindowsByPID(options: CGWindowListOption) -> [Int32:
        [WindowServerWindow]]
    {
        guard
            let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else {
            return [:]
        }

        var byPID: [Int32: [WindowServerWindow]] = [:]
        let screenFrames = NSScreen.screens.map(\.frame)

        for info in windowInfoList {
            guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let ownerPID = ownerPIDNumber.int32Value

            guard let layerNumber = info[kCGWindowLayer as String] as? NSNumber else {
                continue
            }

            let layer = layerNumber.intValue
            guard layer >= 0, layer <= 100
            else {
                continue
            }

            if let alphaNumber = info[kCGWindowAlpha as String] as? NSNumber,
                alphaNumber.doubleValue <= 0
            {
                continue
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            guard let frame = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            guard frame.width > 1, frame.height > 1 else {
                continue
            }

            if !screenFrames.isEmpty,
                !screenFrames.contains(where: { !$0.intersection(frame).isNull })
            {
                continue
            }

            let title = info[kCGWindowName as String] as? String
            byPID[ownerPID, default: []].append(
                WindowServerWindow(title: title, frame: frame, layer: layer)
            )
        }

        for (pid, windows) in byPID {
            byPID[pid] = deduplicatedWindowServerWindows(windows)
        }

        return byPID
    }

    private func preferredOffScreenFallbackWindows(from windows: [WindowServerWindow])
        -> [WindowServerWindow]
    {
        guard !windows.isEmpty else {
            return []
        }

        let trimmed = windows.filter { !looksLikeMenuBarStrip($0.frame) }
        let filtered = trimmed.isEmpty ? windows : trimmed

        // Apps like FreeCAD can hide real windows from optionOnScreenOnly and expose
        // the movable tool windows at non-zero layers in the full list.
        let nonZeroLayer = filtered.filter { $0.layer > 0 }
        let preferred = nonZeroLayer.count >= 2 ? nonZeroLayer : filtered

        return deduplicatedWindowServerWindows(preferred)
    }

    private func looksLikeMenuBarStrip(_ frame: CGRect) -> Bool {
        let maxScreenWidth = NSScreen.screens.map(\.frame.width).max() ?? 0
        guard maxScreenWidth > 0 else {
            return false
        }

        return abs(frame.minY) <= 1 && frame.height <= 40 && frame.width >= (maxScreenWidth * 0.6)
    }

    private func deduplicatedWindowServerWindows(_ windows: [WindowServerWindow])
        -> [WindowServerWindow]
    {
        var seenKeys = Set<String>()
        var unique: [WindowServerWindow] = []
        unique.reserveCapacity(windows.count)

        for window in windows {
            let key = window.identityKey
            if seenKeys.insert(key).inserted {
                unique.append(window)
            }
        }

        unique.sort { lhs, rhs in
            if lhs.layer != rhs.layer {
                return lhs.layer > rhs.layer
            }

            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }

            if lhs.frame.minX != rhs.frame.minX {
                return lhs.frame.minX < rhs.frame.minX
            }

            return lhs.frame.minY < rhs.frame.minY
        }

        return unique
    }

    private func snapshotFrameIdentityKey(_ snapshot: WindowSnapshot) -> String {
        Self.frameIdentityKey(frame: snapshot.frame.cgRect)
    }

    private static func frameIdentityKey(frame: CGRect) -> String {
        let x = Int(frame.origin.x.rounded())
        let y = Int(frame.origin.y.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        return "\(x)|\(y)|\(width)|\(height)"
    }

    private static func windowIdentityKey(title: String?, frame: CGRect) -> String {
        let normalizedTitle =
            title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let frameKey = frameIdentityKey(frame: frame)
        return "\(frameKey)|\(normalizedTitle)"
    }

    private func appendUnique(_ element: AXUIElement, to array: inout [AXUIElement]) {
        if array.contains(where: { CFEqual($0, element) }) {
            return
        }
        array.append(element)
    }

    private func discoverWindowLikeChildren(from root: AXUIElement, maxDepth: Int) -> [AXUIElement]
    {
        var discovered: [AXUIElement] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]

        while let current = queue.first {
            queue.removeFirst()
            if current.depth >= maxDepth {
                continue
            }

            guard
                let childrenValue = copyAttributeValue(
                    element: current.element, attribute: kAXChildrenAttribute as CFString),
                let children = childrenValue as? [AXUIElement]
            else {
                continue
            }

            for child in children {
                if isWindowLikeElement(child) {
                    appendUnique(child, to: &discovered)
                }
                queue.append((child, current.depth + 1))
            }
        }

        return discovered
    }

    private func isWindowLikeElement(_ element: AXUIElement) -> Bool {
        guard frameForWindow(element) != nil else {
            return false
        }

        let role = stringValue(of: element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = stringValue(of: element, attribute: kAXSubroleAttribute as CFString) ?? ""

        if role == kAXWindowRole as String {
            return true
        }

        let windowLikeSubroles: Set<String> = [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
            kAXSystemDialogSubrole as String,
        ]

        if windowLikeSubroles.contains(subrole) {
            return true
        }

        return false
    }

    private struct SetFrameResult {
        let position: AXError
        let size: AXError

        var success: Bool {
            position == .success && size == .success
        }
    }

    private struct WindowServerWindow {
        let title: String?
        let frame: CGRect
        let layer: Int

        var identityKey: String {
            let base = AXWindowSnapshotService.windowIdentityKey(title: title, frame: frame)
            return "\(layer)|\(base)"
        }
    }

    private struct WindowCandidate {
        let title: String?
        let frame: CGRect?
    }
}
