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
    private static let finderBundleID = "com.apple.finder"
    private let workspace: NSWorkspace
    private let screenService: ScreenCoordinateServicing
    private let captureStateLock = NSLock()
    private var explicitlyEmptyAppIdentities: Set<String> = []

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
            setExplicitlyEmptyAppIdentities([])
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
        var explicitEmptyAppsFromCapture: Set<String> = []

        for app in applications {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windows = windowsForAppElement(appElement)
            let isFinder = isFinderBundleID(app.bundleIdentifier)
            if isFinder {
                // Finder sometimes omits window-level entries from kAXWindows while
                // exposing them via child traversal.
                let discoveredFinderWindows = discoverWindowLikeChildren(
                    from: appElement, maxDepth: 3)
                for discovered in discoveredFinderWindows {
                    appendUnique(discovered, to: &windows)
                }
            }
            var appSnapshots: [WindowSnapshot] = []
            appSnapshots.reserveCapacity(windows.count)
            var skippedFullScreenFrameKeys = Set<String>()

            for (index, window) in windows.enumerated() {
                guard !isWindowMinimized(window), let frame = frameForWindow(window) else {
                    continue
                }

                if isWindowFullScreen(window) {
                    // Full-screen windows live in their own macOS space and should
                    // stay under system placement control rather than being moved
                    // by Stay's restore pipeline.
                    skippedFullScreenFrameKeys.insert(Self.frameIdentityKey(frame: frame))
                    logger.debug(
                        "Skipping full-screen window during snapshot capture (pid=\(app.processIdentifier, privacy: .public) title=\(String(describing: self.stringValue(of: window, attribute: kAXTitleAttribute as CFString)), privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public))"
                    )
                    continue
                }

                guard frame.width > 1, frame.height > 1 else {
                    continue
                }

                let windowTitle = stringValue(of: window, attribute: kAXTitleAttribute as CFString)
                let windowRole = stringValue(of: window, attribute: kAXRoleAttribute as CFString)
                let windowSubrole = stringValue(
                    of: window, attribute: kAXSubroleAttribute as CFString)
                if shouldSkipSnapshotWindow(
                    appBundleID: app.bundleIdentifier,
                    title: windowTitle,
                    role: windowRole,
                    subrole: windowSubrole,
                    frame: frame
                ) {
                    continue
                }

                let displayID = screenService.displayID(for: frame)
                if displayID == nil {
                    logger.debug(
                        "Captured window without display ID (pid=\(app.processIdentifier, privacy: .public) title=\(String(describing: windowTitle), privacy: .public))"
                    )
                }

                let snapshot = WindowSnapshot(
                    appPID: app.processIdentifier,
                    appBundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? "Unknown",
                    windowTitle: windowTitle,
                    windowNumber: windowNumber(of: window),
                    windowRole: windowRole,
                    windowSubrole: windowSubrole,
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
            let isAXEmptyAllWindowListFallback =
                appSnapshots.isEmpty && fallbackSource == "all-window-list"
            let finderHasNonWindowRoleSnapshots = appSnapshots.contains { snapshot in
                guard let role = normalizedString(snapshot.windowRole) else {
                    return false
                }
                return role != normalizedString(kAXWindowRole as String)
            }
            let shouldMergeFallbackWindows =
                if isFinder {
                    // Finder normally prefers AX-only capture. If AX includes
                    // non-window pseudo surfaces, treat capture as incomplete and
                    // merge fallback entries to recover missing real windows.
                    appSnapshots.isEmpty || finderHasNonWindowRoleSnapshots
                } else {
                    if appSnapshots.isEmpty {
                        if !skippedFullScreenFrameKeys.isEmpty {
                            false
                        } else if fallbackSource == "all-window-list" {
                            // Generic safeguard: when AX is empty and only the full
                            // window list has candidates, require non-zero-layer
                            // evidence before trusting them as real open windows.
                            hasLayeredFallbackWindows
                        } else {
                            true
                        }
                    } else {
                        hasLayeredFallbackWindows
                    }
                }

            if !fallbackWindows.isEmpty, shouldMergeFallbackWindows {
                var knownFrameKeys = Set(appSnapshots.map(snapshotFrameIdentityKey))
                var appendedFallbackCount = 0

                for fallbackWindow in fallbackWindows {
                    let fallbackFrameKey = Self.frameIdentityKey(frame: fallbackWindow.frame)
                    if skippedFullScreenFrameKeys.contains(fallbackFrameKey) {
                        logger.debug(
                            "Skipping WindowServer fallback for full-screen window (pid=\(app.processIdentifier, privacy: .public) title=\(String(describing: fallbackWindow.title), privacy: .public) frame=\(NSStringFromRect(fallbackWindow.frame), privacy: .public))"
                        )
                        continue
                    }

                    if shouldSkipSnapshotWindow(
                        appBundleID: app.bundleIdentifier,
                        title: fallbackWindow.title,
                        role: nil,
                        subrole: nil,
                        frame: fallbackWindow.frame
                    ) {
                        continue
                    }

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
                        windowNumber: fallbackWindow.windowNumber,
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
            } else if isAXEmptyAllWindowListFallback {
                logger.debug(
                    "Skipped WindowServer all-window-list fallback for pid=\(app.processIdentifier, privacy: .public) because AX captured no windows and fallback had no non-zero-layer evidence; treating app as having no open windows"
                )
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
                explicitEmptyAppsFromCapture.insert(
                    Self.appIdentity(bundleID: app.bundleIdentifier, pid: app.processIdentifier))
                logger.debug(
                    "Captured 0 snapshot(s) for app=\(app.localizedName ?? "Unknown", privacy: .public) pid=\(app.processIdentifier, privacy: .public)"
                )
            }
        }

        setExplicitlyEmptyAppIdentities(explicitEmptyAppsFromCapture)

        logger.info(
            "Capture produced \(snapshots.count, privacy: .public) snapshot(s) across \(applications.count, privacy: .public) app(s)"
        )
        return snapshots
    }

    func explicitlyEmptyAppIdentitiesFromLastCapture() -> Set<String> {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return explicitlyEmptyAppIdentities
    }

    private func setExplicitlyEmptyAppIdentities(_ identities: Set<String>) {
        captureStateLock.lock()
        explicitlyEmptyAppIdentities = identities
        captureStateLock.unlock()
    }

    private static func appIdentity(bundleID: String?, pid: Int32) -> String {
        if let bundleID, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "pid:\(pid)"
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

        // Restore pipeline per invocation:
        // 1) partition snapshots per app and per active space,
        // 2) opportunistically expose AX windows (activation where safe),
        // 3) confidence-match snapshots to live windows,
        // 4) apply frame writes with app-specific convergence checks,
        // 5) return structured progress so coordinator can decide retry/park.
        // Group by process to avoid cross-app window matching.
        let grouped = groupedSnapshotsByTargetPID(snapshots)
        let onScreenWindowNumbersByPID = onScreenWindowNumbersByPID()
        // Coordinator treats this as a success signal for ending post-wake retries.
        var movedWindowCount = 0
        var alreadyAlignedCount = 0
        var recoverableFailureCount = 0
        // "Deferred" snapshots are windows we intentionally skip this attempt
        // because AX has not exposed enough windows for a safe restore yet.
        var deferredSnapshotCount = 0
        // Workspace-specific deferrals are tracked explicitly so coordinator
        // can wait for active-space changes without conflating app-readiness delays.
        var deferredInactiveWorkspaceSnapshots: [WindowSnapshot] = []
        var resolvedSnapshots: [WindowSnapshot] = []
        logger.info(
            "Starting restore for \(snapshots.count, privacy: .public) snapshot(s) across \(grouped.count, privacy: .public) app(s)"
        )
        let originalFrontmostPID = workspace.frontmostApplication?.processIdentifier
        var activatedPIDsForWindowExposure = Set<Int32>()

        for (appPID, appSnapshots) in grouped {
            let appBundleID = appSnapshots.first?.appBundleID
            let onScreenWindowNumbers = onScreenWindowNumbersByPID[appPID] ?? []
            let partitionedSnapshots = partitionSnapshotsByCurrentSpace(
                appSnapshots,
                onScreenWindowNumbers: onScreenWindowNumbers
            )
            let eligibleSnapshots = partitionedSnapshots.eligible
            let inactiveSpaceDeferredSnapshots = partitionedSnapshots.deferred

            if !inactiveSpaceDeferredSnapshots.isEmpty {
                recoverableFailureCount += inactiveSpaceDeferredSnapshots.count
                deferredSnapshotCount += inactiveSpaceDeferredSnapshots.count
                deferredInactiveWorkspaceSnapshots.append(
                    contentsOf: inactiveSpaceDeferredSnapshots)
                logger.debug(
                    "Deferring \(inactiveSpaceDeferredSnapshots.count, privacy: .public) snapshot(s) for pid=\(appPID, privacy: .public) because windows are not in the active space (onScreenWindowNumbers=\(onScreenWindowNumbers.count, privacy: .public))"
                )
            }

            guard !eligibleSnapshots.isEmpty else {
                continue
            }

            let eligibleRestorableSnapshots = eligibleSnapshots

            let appElement = AXUIElementCreateApplication(appPID)
            var windows = windowsForAppElement(appElement)

            if shouldAttemptActivationForWindowExposure(
                appPID: appPID,
                snapshots: eligibleRestorableSnapshots,
                windows: windows,
                originalFrontmostPID: originalFrontmostPID
            ),
                activateAppForWindowExposure(pid: appPID)
            {
                activatedPIDsForWindowExposure.insert(appPID)
                logger.debug(
                    "Activated app pid=\(appPID, privacy: .public) to expose AX windows for restore"
                )
                windows = waitForWindowExposure(
                    appElement: appElement,
                    minimumCount: 1
                )
            }

            if isFinderBundleID(appBundleID),
                appPID != originalFrontmostPID,
                activateAppForWindowExposure(pid: appPID)
            {
                activatedPIDsForWindowExposure.insert(appPID)
                logger.debug(
                    "Activated Finder pid=\(appPID, privacy: .public) before restore to improve AX frame-write reliability"
                )
                windows = waitForWindowExposure(
                    appElement: appElement,
                    minimumCount: max(1, windows.count)
                )
            }

            if isFinderBundleID(appBundleID) {
                // Finder frequently includes AX windows that reject frame writes
                // (for example, pseudo windows). Keep Finder-specific filtering
                // isolated so behavior for other apps remains unchanged.
                let settableWindows = windowsWithSettableFrameAttributes(windows)
                if !settableWindows.isEmpty, settableWindows.count < windows.count {
                    logger.debug(
                        "Finder restore filtered non-settable AX windows (settable=\(settableWindows.count, privacy: .public) total=\(windows.count, privacy: .public))"
                    )
                    windows = settableWindows
                }
            }

            let requiresFullExposure =
                shouldRequireFullExposure(for: eligibleRestorableSnapshots)
                && windows.count < eligibleRestorableSnapshots.count
            if requiresFullExposure {
                recoverableFailureCount += eligibleRestorableSnapshots.count
                deferredSnapshotCount += eligibleRestorableSnapshots.count
                logger.warning(
                    "App pid=\(appPID, privacy: .public) exposed \(windows.count, privacy: .public)/\(eligibleRestorableSnapshots.count, privacy: .public) window(s) for an ambiguous multi-window restore set; deferring app restore"
                )
                continue
            }

            guard !windows.isEmpty else {
                if isAppRunning(pid: appPID) {
                    recoverableFailureCount += eligibleRestorableSnapshots.count
                    deferredSnapshotCount += eligibleRestorableSnapshots.count
                    logger.warning(
                        "App pid=\(appPID, privacy: .public) is running but has no AX windows yet; deferring \(eligibleRestorableSnapshots.count, privacy: .public) eligible snapshot(s)"
                    )
                }
                logger.debug(
                    "No AX windows available for pid=\(appPID, privacy: .public) during restore"
                )
                continue
            }

            logger.debug(
                "Restore app pid=\(appPID, privacy: .public) snapshots=\(eligibleRestorableSnapshots.count, privacy: .public) liveWindows=\(windows.count, privacy: .public) deferredInactiveSpace=\(inactiveSpaceDeferredSnapshots.count, privacy: .public)"
            )
            let candidates = windows.enumerated().map { index, window in
                WindowCandidate(
                    windowIndex: index,
                    title: stringValue(of: window, attribute: kAXTitleAttribute as CFString),
                    frame: frameForWindow(window),
                    windowNumber: windowNumber(of: window),
                    role: stringValue(of: window, attribute: kAXRoleAttribute as CFString),
                    subrole: stringValue(of: window, attribute: kAXSubroleAttribute as CFString)
                )
            }
            let orderedSnapshots = eligibleRestorableSnapshots.sorted(by: {
                $0.windowIndex < $1.windowIndex
            })
            let assignments = assignedWindowIndices(
                snapshots: orderedSnapshots,
                candidates: candidates
            )

            // If every matched window is already on its captured display, skip
            // frame writes to avoid visible no-op movement/resizing after wake
            // when macOS preserved placement but adjusted app-managed frame data.
            if areAssignmentsDisplayAligned(
                snapshots: orderedSnapshots,
                candidates: candidates,
                assignments: assignments
            ) {
                alreadyAlignedCount += orderedSnapshots.count
                resolvedSnapshots.append(contentsOf: orderedSnapshots)
                logger.debug(
                    "Skipping frame writes for pid=\(appPID, privacy: .public) because all matched windows are already on expected displays"
                )
                continue
            }

            for (snapshotIndex, snapshot) in orderedSnapshots.enumerated() {
                guard let windowIndex = assignments[snapshotIndex] else {
                    recoverableFailureCount += 1
                    logger.debug(
                        "Could not match snapshot window for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) index=\(snapshot.windowIndex, privacy: .public)"
                    )
                    continue
                }

                let adjustedFrame = screenService.adjustedFrame(
                    snapshot.frame.cgRect,
                    preferredDisplayID: snapshot.screenDisplayID
                )
                let isFinderWindow = isFinderBundleID(snapshot.appBundleID)
                if isFinderWindow {
                    if let currentFrame = frameForWindow(windows[windowIndex]),
                        isFinderWindowAligned(
                            currentFrame: currentFrame,
                            preferredDisplayID: snapshot.screenDisplayID
                        )
                    {
                        alreadyAlignedCount += 1
                        resolvedSnapshots.append(snapshot)
                        continue
                    }

                    _ = raiseWindowIfSupported(windows[windowIndex])
                    let finderOutcome = moveFinderWindow(
                        windows[windowIndex],
                        targetFrame: adjustedFrame,
                        preferredDisplayID: snapshot.screenDisplayID
                    )
                    switch finderOutcome {
                    case .aligned:
                        alreadyAlignedCount += 1
                        resolvedSnapshots.append(snapshot)
                    case .moved:
                        movedWindowCount += 1
                        resolvedSnapshots.append(snapshot)
                    case .failed:
                        recoverableFailureCount += 1
                        logger.warning(
                            "Finder position restore failed to converge for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) candidateIndex=\(windowIndex, privacy: .public)"
                        )
                    }
                    continue
                }

                if let currentFrame = frameForWindow(windows[windowIndex]),
                    isApproximatelySameFrame(currentFrame, adjustedFrame)
                {
                    alreadyAlignedCount += 1
                    resolvedSnapshots.append(snapshot)
                    continue
                }

                let setFrameResult = setFrame(
                    adjustedFrame,
                    for: windows[windowIndex]
                )
                if setFrameResult.success {
                    // Some apps report AX success but immediately snap windows back.
                    // Count a move only after the frame actually converges.
                    if didFrameConverge(
                        for: windows[windowIndex],
                        expectedFrame: adjustedFrame,
                        waitDuration: 0.2
                    ) {
                        movedWindowCount += 1
                        resolvedSnapshots.append(snapshot)
                    } else {
                        recoverableFailureCount += 1
                        logger.warning(
                            "AX setFrame reported success but frame did not converge for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) candidateIndex=\(windowIndex, privacy: .public)"
                        )
                    }
                } else {
                    if isRecoverableAXError(setFrameResult.position)
                        || isRecoverableAXError(setFrameResult.size)
                    {
                        recoverableFailureCount += 1
                    }
                    logger.warning(
                        "AX setFrame failed for pid=\(appPID, privacy: .public) title=\(String(describing: snapshot.windowTitle), privacy: .public) candidateIndex=\(windowIndex, privacy: .public) positionError=\(setFrameResult.position.rawValue, privacy: .public) sizeError=\(setFrameResult.size.rawValue, privacy: .public)"
                    )
                }
            }
        }

        restoreFrontmostApplicationIfNeeded(
            originalFrontmostPID: originalFrontmostPID,
            activatedPIDsForWindowExposure: activatedPIDsForWindowExposure
        )

        logger.info(
            "Restore finished with movedWindowCount=\(movedWindowCount, privacy: .public) alreadyAlignedCount=\(alreadyAlignedCount, privacy: .public) recoverableFailureCount=\(recoverableFailureCount, privacy: .public) deferredSnapshotCount=\(deferredSnapshotCount, privacy: .public) deferredInactiveWorkspaceCount=\(deferredInactiveWorkspaceSnapshots.count, privacy: .public)"
        )
        return WindowRestoreResult(
            isComplete: recoverableFailureCount == 0,
            movedWindowCount: movedWindowCount,
            alreadyAlignedCount: alreadyAlignedCount,
            recoverableFailureCount: recoverableFailureCount,
            deferredSnapshotCount: deferredSnapshotCount,
            deferredInactiveWorkspaceSnapshots: deferredInactiveWorkspaceSnapshots,
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

    private func isWindowFullScreen(_ window: AXUIElement) -> Bool {
        guard let value = copyAttributeValue(element: window, attribute: "AXFullScreen" as CFString)
        else {
            return false
        }

        return (value as? Bool) ?? false
    }

    private func setFrame(
        _ frame: CGRect,
        for window: AXUIElement
    ) -> SetFrameResult {
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

        if positionResult == .success && sizeResult == .success {
            return SetFrameResult(position: positionResult, size: sizeResult)
        }

        return SetFrameResult(position: positionResult, size: sizeResult)
    }

    private func setFrameAttribute(_ frame: CGRect, for window: AXUIElement) -> AXError {
        var mutableFrame = frame
        guard let frameValue = AXValueCreate(.cgRect, &mutableFrame) else {
            return .failure
        }

        let frameAttribute = "AXFrame" as CFString

        return AXUIElementSetAttributeValue(
            window, frameAttribute, frameValue
        )
    }

    private func setPosition(_ origin: CGPoint, for window: AXUIElement) -> AXError {
        var mutableOrigin = origin
        guard let positionValue = AXValueCreate(.cgPoint, &mutableOrigin) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue
        )
    }

    private enum FinderMoveOutcome {
        case moved
        case aligned
        case failed
    }

    private func moveFinderWindow(
        _ window: AXUIElement,
        targetFrame: CGRect,
        preferredDisplayID: UInt32?
    ) -> FinderMoveOutcome {
        if let currentFrame = frameForWindow(window),
            isFinderWindowAligned(
                currentFrame: currentFrame,
                preferredDisplayID: preferredDisplayID
            )
        {
            return .aligned
        }

        let frameWithCurrentSize: CGRect
        if let currentFrame = frameForWindow(window) {
            frameWithCurrentSize = CGRect(origin: targetFrame.origin, size: currentFrame.size)
        } else {
            frameWithCurrentSize = targetFrame
        }

        let positionResult = setPosition(targetFrame.origin, for: window)
        if didFinderWindowConverge(
            for: window,
            targetOrigin: targetFrame.origin,
            preferredDisplayID: preferredDisplayID,
            waitDuration: 0.6
        ) {
            return .moved
        }

        // Finder can report successful position writes but keep the window on the
        // wrong display. Force a frame write as a second step before failing.
        let fallbackFrameResult = setFrameAttribute(frameWithCurrentSize, for: window)
        if fallbackFrameResult != .success, positionResult != .success {
            return .failed
        }

        let convergedAfterFallback = didFinderWindowConverge(
            for: window,
            targetOrigin: targetFrame.origin,
            preferredDisplayID: preferredDisplayID,
            waitDuration: 0.6
        )
        return convergedAfterFallback ? .moved : .failed
    }

    private func isFinderWindowAligned(
        currentFrame: CGRect,
        preferredDisplayID: UInt32?
    ) -> Bool {
        guard let preferredDisplayID else {
            return false
        }

        return screenService.displayID(for: currentFrame) == preferredDisplayID
    }

    private func didFinderWindowConverge(
        for window: AXUIElement,
        targetOrigin: CGPoint,
        preferredDisplayID: UInt32?,
        waitDuration: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(waitDuration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            guard let frame = frameForWindow(window) else {
                continue
            }

            if let preferredDisplayID,
                screenService.displayID(for: frame) == preferredDisplayID
            {
                return true
            }

            // Fallback when display ID inference is unavailable.
            if abs(frame.minX - targetOrigin.x) <= 60,
                abs(frame.minY - targetOrigin.y) <= 60
            {
                return true
            }
        }

        return false
    }

    private func didFrameConverge(
        for window: AXUIElement,
        expectedFrame: CGRect,
        waitDuration: TimeInterval
    ) -> Bool {
        if let frame = frameForWindow(window),
            isApproximatelySameFrame(frame, expectedFrame)
        {
            return true
        }

        let deadline = Date().addingTimeInterval(waitDuration)
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

    private func windowNumber(of element: AXUIElement) -> Int? {
        let attribute = "AXWindowNumber" as CFString
        guard
            let value = copyAttributeValue(
                element: element, attribute: attribute)
        else {
            return nil
        }

        return (value as? NSNumber)?.intValue
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

    private func assignedWindowIndices(
        snapshots: [WindowSnapshot],
        candidates: [WindowCandidate]
    ) -> [Int: Int] {
        guard !snapshots.isEmpty, !candidates.isEmpty else {
            return [:]
        }

        var scoredPairs: [MatchPair] = []
        scoredPairs.reserveCapacity(snapshots.count * candidates.count)

        for (snapshotIndex, snapshot) in snapshots.enumerated() {
            for (candidateIndex, candidate) in candidates.enumerated() {
                guard
                    let score = matchScore(
                        snapshot: snapshot,
                        candidate: candidate,
                        snapshotCount: snapshots.count
                    )
                else {
                    continue
                }

                scoredPairs.append(
                    MatchPair(
                        snapshotIndex: snapshotIndex,
                        candidateIndex: candidateIndex,
                        score: score
                    )
                )
            }
        }

        // Score every snapshot-window pair, then pick the best non-conflicting
        // assignments across the whole app restore set.
        scoredPairs.sort { lhs, rhs in
            if lhs.score.strength != rhs.score.strength {
                return lhs.score.strength.rawValue > rhs.score.strength.rawValue
            }

            if lhs.score.frameDistance != rhs.score.frameDistance {
                return lhs.score.frameDistance < rhs.score.frameDistance
            }

            if lhs.score.indexDistance != rhs.score.indexDistance {
                return lhs.score.indexDistance < rhs.score.indexDistance
            }

            if lhs.snapshotIndex != rhs.snapshotIndex {
                return snapshots[lhs.snapshotIndex].windowIndex
                    < snapshots[rhs.snapshotIndex].windowIndex
            }

            return lhs.candidateIndex < rhs.candidateIndex
        }

        var assignments: [Int: Int] = [:]
        var usedSnapshots = Set<Int>()
        var usedCandidates = Set<Int>()

        for pair in scoredPairs {
            guard !usedSnapshots.contains(pair.snapshotIndex) else {
                continue
            }

            guard !usedCandidates.contains(pair.candidateIndex) else {
                continue
            }

            assignments[pair.snapshotIndex] = pair.candidateIndex
            usedSnapshots.insert(pair.snapshotIndex)
            usedCandidates.insert(pair.candidateIndex)
        }

        return assignments
    }

    private func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else {
            return nil
        }
        return value.lowercased()
    }

    private func areAssignmentsDisplayAligned(
        snapshots: [WindowSnapshot],
        candidates: [WindowCandidate],
        assignments: [Int: Int]
    ) -> Bool {
        guard !snapshots.isEmpty, assignments.count == snapshots.count else {
            return false
        }

        for (snapshotIndex, snapshot) in snapshots.enumerated() {
            guard let expectedDisplayID = snapshot.screenDisplayID else {
                return false
            }

            guard
                let candidateIndex = assignments[snapshotIndex],
                candidates.indices.contains(candidateIndex),
                let frame = candidates[candidateIndex].frame,
                let candidateDisplayID = screenService.displayID(for: frame),
                candidateDisplayID == expectedDisplayID
            else {
                return false
            }
        }

        return true
    }

    private func shouldSkipSnapshotWindow(
        appBundleID: String?,
        title: String?,
        role: String?,
        subrole: String?,
        frame: CGRect?
    ) -> Bool {
        guard isFinderBundleID(appBundleID) else {
            return false
        }

        if let normalizedRole = normalizedString(role),
            normalizedRole != normalizedString(kAXWindowRole as String)
        {
            logger.debug(
                "Skipping Finder non-window pseudo-surface during snapshot capture (role=\(String(describing: role), privacy: .public) subrole=\(String(describing: subrole), privacy: .public))"
            )
            return true
        }

        // Finder exposes a Desktop pseudo-window that is not meaningfully
        // restorable via AX positioning and pollutes multi-window matching.
        let normalizedTitle = normalizedString(title)
        if normalizedTitle == "desktop" {
            logger.debug(
                "Skipping Finder Desktop pseudo-window during snapshot capture (role=\(String(describing: role), privacy: .public) subrole=\(String(describing: subrole), privacy: .public))"
            )
            return true
        }

        if normalizedTitle == nil,
            let frame,
            looksLikeFinderVirtualDesktopSurface(frame)
        {
            logger.debug(
                "Skipping Finder virtual-desktop pseudo-surface during snapshot capture (frame=\(NSStringFromRect(frame), privacy: .public))"
            )
            return true
        }

        return false
    }

    private func isFinderBundleID(_ bundleID: String?) -> Bool {
        bundleID == Self.finderBundleID
    }

    private func looksLikeFinderVirtualDesktopSurface(_ frame: CGRect) -> Bool {
        let screenFrames = NSScreen.screens.map(\.frame)
        guard !screenFrames.isEmpty else {
            return false
        }

        let virtualDesktopFrame = screenFrames.reduce(CGRect.null) { partial, screenFrame in
            partial.union(screenFrame)
        }
        let virtualDesktopArea =
            max(0, virtualDesktopFrame.width) * max(0, virtualDesktopFrame.height)
        guard virtualDesktopArea > 0 else {
            return false
        }

        let nearGlobalBounds =
            abs(frame.minX - virtualDesktopFrame.minX) <= 2
            && abs(frame.maxX - virtualDesktopFrame.maxX) <= 2
            && abs(frame.minY - virtualDesktopFrame.minY) <= 2
            && abs(frame.maxY - virtualDesktopFrame.maxY) <= 2

        let overlapFrame = frame.intersection(virtualDesktopFrame)
        let overlapArea = max(0, overlapFrame.width) * max(0, overlapFrame.height)
        let coverage = overlapArea / virtualDesktopArea

        return nearGlobalBounds || coverage >= 0.95
    }

    private func windowsWithSettableFrameAttributes(_ windows: [AXUIElement]) -> [AXUIElement] {
        windows.filter { window in
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
    }

    private func raiseWindowIfSupported(_ window: AXUIElement) -> Bool {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private func matchScore(
        snapshot: WindowSnapshot,
        candidate: WindowCandidate,
        snapshotCount: Int
    ) -> MatchScore? {
        let frameDistance: CGFloat
        if let candidateFrame = candidate.frame {
            frameDistance = frameDistanceScore(snapshot.frame.cgRect, candidateFrame)
        } else {
            frameDistance = CGFloat.greatestFiniteMagnitude
        }
        let indexDistance = abs(snapshot.windowIndex - candidate.windowIndex)

        if let snapshotWindowNumber = snapshot.windowNumber,
            let candidateWindowNumber = candidate.windowNumber
        {
            guard snapshotWindowNumber == candidateWindowNumber else {
                return nil
            }
            return MatchScore(
                strength: .windowNumber,
                frameDistance: frameDistance,
                indexDistance: indexDistance
            )
        }

        if let snapshotRole = normalizedString(snapshot.windowRole),
            let snapshotSubrole = normalizedString(snapshot.windowSubrole),
            normalizedString(candidate.role) == snapshotRole,
            normalizedString(candidate.subrole) == snapshotSubrole
        {
            return MatchScore(
                strength: .roleSubrole,
                frameDistance: frameDistance,
                indexDistance: indexDistance
            )
        }

        if let snapshotTitle = normalizedString(snapshot.windowTitle),
            let candidateTitle = normalizedString(candidate.title),
            snapshotTitle == candidateTitle
        {
            return MatchScore(
                strength: .title,
                frameDistance: frameDistance,
                indexDistance: indexDistance
            )
        }

        if candidate.frame != nil {
            return MatchScore(
                strength: .frame,
                frameDistance: frameDistance,
                indexDistance: indexDistance
            )
        }

        // Index-only identity is intentionally weak; allow it only for
        // single-window restore sets to avoid multi-window cross-matching.
        let hasUsableIndexIdentity = snapshot.windowIndex >= 0 && candidate.windowIndex >= 0
        if hasUsableIndexIdentity && snapshotCount == 1 {
            return MatchScore(
                strength: .index,
                frameDistance: frameDistance,
                indexDistance: indexDistance
            )
        }

        return nil
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

    private func onScreenWindowNumbersByPID() -> [Int32: Set<Int>] {
        let onScreenWindows = windowServerWindowsByPID(options: [.optionOnScreenOnly])
        var result: [Int32: Set<Int>] = [:]

        for (pid, windows) in onScreenWindows {
            let numbers = Set(windows.compactMap(\.windowNumber))
            if !numbers.isEmpty {
                result[pid] = numbers
            }
        }

        return result
    }

    private func partitionSnapshotsByCurrentSpace(
        _ snapshots: [WindowSnapshot],
        onScreenWindowNumbers: Set<Int>
    ) -> (eligible: [WindowSnapshot], deferred: [WindowSnapshot]) {
        guard !snapshots.isEmpty else {
            return ([], [])
        }

        // If we have enough identity to reason about active-space visibility,
        // only attempt windows currently visible in the active space.
        let snapshotsWithWindowNumbers = snapshots.compactMap(\.windowNumber)
        guard !snapshotsWithWindowNumbers.isEmpty else {
            return (snapshots, [])
        }

        if onScreenWindowNumbers.isEmpty {
            // The app currently has no visible WindowServer windows in this
            // space/session, so restoring these snapshots now is likely wrong.
            return ([], snapshots)
        }

        let snapshotWindowNumbers = Set(snapshotsWithWindowNumbers)
        let overlapWindowNumbers = snapshotWindowNumbers.intersection(onScreenWindowNumbers)
        if overlapWindowNumbers.isEmpty {
            // Window numbers are not stable across every sleep/wake cycle
            // (Finder is a common example). If we have visible windows but no
            // number overlap, avoid deferring the entire app and fall back to
            // title/frame matching for this attempt.
            logger.debug(
                "Window-number overlap is empty despite visible windows; bypassing strict active-space partition for this app"
            )
            return (snapshots, [])
        }

        var eligible: [WindowSnapshot] = []
        var deferred: [WindowSnapshot] = []
        eligible.reserveCapacity(snapshots.count)
        deferred.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            if let snapshotWindowNumber = snapshot.windowNumber {
                if onScreenWindowNumbers.contains(snapshotWindowNumber) {
                    eligible.append(snapshot)
                } else {
                    deferred.append(snapshot)
                }
                continue
            }

            // Mixed-identity snapshot sets are risky for multi-window apps.
            // If we cannot prove active-space visibility for this snapshot,
            // defer and wait for the app/space to expose it.
            if snapshots.count > 1 {
                deferred.append(snapshot)
            } else {
                eligible.append(snapshot)
            }
        }

        return (eligible, deferred)
    }

    private func shouldAttemptActivationForWindowExposure(
        appPID: Int32,
        snapshots: [WindowSnapshot],
        windows: [AXUIElement],
        originalFrontmostPID: Int32?
    ) -> Bool {
        guard windows.isEmpty else {
            return false
        }

        guard isAppRunning(pid: appPID) else {
            return false
        }

        guard appPID != originalFrontmostPID else {
            return false
        }

        // Phase 2 activation policy: avoid activating multi-window apps during
        // wake restore. Activation can drag windows/spaces visibly and cause
        // repeated flashing loops.
        guard snapshots.count == 1 else {
            return false
        }

        // If we already have a concrete window number, prefer waiting for a
        // space/session environment change instead of force-activating.
        if snapshots[0].windowNumber != nil {
            return false
        }

        return true
    }

    private func shouldRequireFullExposure(for snapshots: [WindowSnapshot]) -> Bool {
        guard snapshots.count > 1 else {
            return false
        }

        // If we have window numbers, we can match partial visibility safely.
        let hasWindowNumbers = snapshots.contains(where: { $0.windowNumber != nil })
        if hasWindowNumbers {
            return false
        }

        // Without titles or window numbers, partial app visibility is too
        // ambiguous for reliable matching.
        return snapshots.allSatisfy { snapshot in
            let normalizedTitle =
                snapshot.windowTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return normalizedTitle.isEmpty
        }
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

            let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue

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
                WindowServerWindow(
                    title: title,
                    frame: frame,
                    layer: layer,
                    windowNumber: windowNumber
                )
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
        let windowNumber: Int?

        var identityKey: String {
            if let windowNumber {
                return "\(windowNumber)"
            }
            let base = AXWindowSnapshotService.windowIdentityKey(title: title, frame: frame)
            return "\(layer)|\(base)"
        }
    }

    private struct WindowCandidate {
        let windowIndex: Int
        let title: String?
        let frame: CGRect?
        let windowNumber: Int?
        let role: String?
        let subrole: String?
    }

    private enum MatchStrength: Int {
        case windowNumber = 500
        case roleSubrole = 400
        case title = 300
        case frame = 200
        case index = 100
    }

    private struct MatchScore {
        let strength: MatchStrength
        let frameDistance: CGFloat
        let indexDistance: Int
    }

    private struct MatchPair {
        let snapshotIndex: Int
        let candidateIndex: Int
        let score: MatchScore
    }
}
