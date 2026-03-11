import Foundation
import OSLog

/// Environment-change signals that can unblock deferred post-wake restores.
public enum EnvironmentChangeKind: String, Sendable {
    case unspecified
    case screensDidWake
    case sessionDidBecomeActive
    case activeSpaceDidChange
}

// Design goal: deterministic, resilient sleep/wake handling that tolerates
// repeated or out-of-order events and delays restore until conditions are safe.
/// Coordinates capture on sleep and retrying restore attempts after wake.
public final class SleepWakeCoordinator {
    private let logger = Logger(subsystem: "com.stay.app", category: "SleepWakeCoordinator")

    private let capturing: WindowSnapshotCapturing
    private let restoring: WindowSnapshotRestoring
    private let repository: SnapshotRepository
    private let readinessChecker: RestoreReadinessChecking
    private let scheduler: SleepWakeScheduling
    private let wakeDelay: TimeInterval
    private let retryInterval: TimeInterval
    private let maxWaitAfterWake: TimeInterval
    private let maxStagnantAttemptsBeforeEnvironmentWait: Int
    private let maxPostTimeoutEnvironmentRetries: Int

    private let lock = NSLock()
    // Top-level sleep gate: wake events are ignored unless a corresponding
    // sleep cycle was observed.
    private var isSleeping = false
    // Last capture payload to restore after wake; overwritten on every sleep.
    private var cachedSnapshots: [WindowSnapshot] = []
    // Unresolved work for the current wake cycle.
    private var pendingRestoreSnapshots: [WindowSnapshot] = []
    // Subset of pending snapshots known to belong to inactive workspaces.
    // These are re-queued only after `activeSpaceDidChange`.
    private var inactiveWorkspacePendingSnapshots: [WindowSnapshot] = []
    private var isAwaitingPostWakeRestore = false
    private var restoreDeadline: Date?
    private var restoreTask: CancellableTask?
    // Retry/convergence tracking for the current wake cycle.
    private var stagnantRestoreAttemptCount = 0
    private var bestRecoverableFailureCount: Int?
    private var postTimeoutRetryCount = 0
    private var hasObservedPlacementProgress = false
    private var lastIncompleteRestoreResult: WindowRestoreResult?
    // Deferred-space wait mode: pause interval retries until an environment
    // signal indicates hidden/inactive-space windows may be exposed again.
    private var isWaitingForDeferredSpaceExposure = false
    private var requiresActiveSpaceChangeForDeferredRestore = false

    /// Creates a coordinator with injected capture/restore and scheduling dependencies.
    public init(
        capturing: WindowSnapshotCapturing,
        restoring: WindowSnapshotRestoring,
        repository: SnapshotRepository,
        readinessChecker: RestoreReadinessChecking = ImmediateRestoreReadinessChecker(),
        scheduler: SleepWakeScheduling,
        wakeDelay: TimeInterval = 1.5,
        retryInterval: TimeInterval = 1.0,
        maxWaitAfterWake: TimeInterval = 20.0,
        maxStagnantAttemptsBeforeEnvironmentWait: Int = 3,
        maxPostTimeoutEnvironmentRetries: Int = 2
    ) {
        self.capturing = capturing
        self.restoring = restoring
        self.repository = repository
        self.readinessChecker = readinessChecker
        self.scheduler = scheduler
        self.wakeDelay = wakeDelay
        self.retryInterval = retryInterval
        self.maxWaitAfterWake = maxWaitAfterWake
        self.maxStagnantAttemptsBeforeEnvironmentWait = max(
            1, maxStagnantAttemptsBeforeEnvironmentWait)
        self.maxPostTimeoutEnvironmentRetries = max(1, maxPostTimeoutEnvironmentRetries)

        logger.info(
            "Initialized (wakeDelay=\(wakeDelay, privacy: .public)s retryInterval=\(retryInterval, privacy: .public)s maxWaitAfterWake=\(maxWaitAfterWake, privacy: .public)s maxStagnantAttemptsBeforeEnvironmentWait=\(self.maxStagnantAttemptsBeforeEnvironmentWait, privacy: .public) maxPostTimeoutEnvironmentRetries=\(self.maxPostTimeoutEnvironmentRetries, privacy: .public))"
        )
    }

    /// Handles a pre-sleep event by capturing and persisting snapshots.
    public func handleWillSleep() {
        // Capture as late as possible before sleep and cancel any pending restore.
        let latestSnapshots = capturing.capture()
        let explicitlyEmptyAppIdentities = capturing.explicitlyEmptyAppIdentitiesFromLastCapture()
        let persistedSnapshots = repository.load()
        let snapshots = SnapshotSetOperations.mergeLatestWithFallback(
            latest: latestSnapshots,
            fallback: persistedSnapshots,
            explicitlyEmptyAppIdentities: explicitlyEmptyAppIdentities
        )

        logger.info(
            "Received willSleep; latest=\(latestSnapshots.count, privacy: .public) persisted=\(persistedSnapshots.count, privacy: .public) explicitEmptyApps=\(explicitlyEmptyAppIdentities.count, privacy: .public) merged=\(snapshots.count, privacy: .public)"
        )

        lock.lock()
        clearRestoreState()
        // Always overwrite the cache for the new sleep cycle, even when empty,
        // so stale prior-cycle snapshots are never reused accidentally.
        cachedSnapshots = snapshots
        isSleeping = true
        lock.unlock()

        if !snapshots.isEmpty {
            repository.save(snapshots)
            logger.info("Persisted \(snapshots.count, privacy: .public) snapshot(s)")
        } else {
            logger.warning("No snapshots captured during willSleep")
        }
    }

    /// Handles a wake event by scheduling post-wake restore attempts.
    public func handleDidWake() {
        lock.lock()
        guard isSleeping else {
            logger.debug("Ignoring didWake because coordinator is not in sleeping state")
            lock.unlock()
            return
        }

        isSleeping = false
        var snapshots = cachedSnapshots
        if snapshots.isEmpty {
            snapshots = repository.load()
            logger.info(
                "Loaded \(snapshots.count, privacy: .public) snapshot(s) from repository after wake"
            )
        }

        guard !snapshots.isEmpty else {
            clearRestoreState()
            lock.unlock()
            return
        }

        isAwaitingPostWakeRestore = true
        pendingRestoreSnapshots = snapshots
        inactiveWorkspacePendingSnapshots = []
        restoreDeadline = Date().addingTimeInterval(maxWaitAfterWake)
        resetRestoreAttemptTracking()
        clearDeferredExposureWait()
        if let restoreDeadline {
            logger.info(
                "Wake cycle started; awaiting restore for \(snapshots.count, privacy: .public) snapshot(s) with deadline \(restoreDeadline.ISO8601Format(), privacy: .public)"
            )
        }
        scheduleRestoreAttempt(after: wakeDelay)
        lock.unlock()
    }

    /// Handles environment signals that may unblock deferred restore work.
    public func handleEnvironmentDidChange(_ kind: EnvironmentChangeKind = .unspecified) {
        lock.lock()
        guard !isSleeping, isAwaitingPostWakeRestore else {
            lock.unlock()
            return
        }

        if kind == .activeSpaceDidChange {
            let promotedCount = promoteInactiveWorkspaceSnapshotsToActive()
            if promotedCount > 0 {
                logger.debug(
                    "Promoted \(promotedCount, privacy: .public) inactive-workspace snapshot(s) into active restore queue after space change"
                )
            }
        }

        if isWaitingForDeferredSpaceExposure,
            requiresActiveSpaceChangeForDeferredRestore,
            kind != .activeSpaceDidChange
        {
            logger.debug(
                "Ignoring environment change (\(kind.rawValue, privacy: .public)) while waiting specifically for active-space change"
            )
            lock.unlock()
            return
        }

        // Environment signals (screens/session/workspace) are strong indicators
        // that windows are now accessible after wake or unlock.
        logger.debug(
            "Environment change signal received (\(kind.rawValue, privacy: .public)); scheduling immediate restore attempt"
        )
        scheduleRestoreAttempt(after: 0.25)
        lock.unlock()
    }

    private func scheduleRestoreAttempt(after delay: TimeInterval) {
        logger.debug("Scheduling restore attempt in \(delay, privacy: .public)s")
        restoreTask?.cancel()
        restoreTask = scheduler.schedule(after: delay) { [weak self] in
            self?.runRestoreAttempt()
        }
    }

    private func runRestoreAttempt() {
        lock.lock()
        if isSleeping || !isAwaitingPostWakeRestore {
            lock.unlock()
            return
        }

        let snapshots = activeWorkspacePendingSnapshots()
        if snapshots.isEmpty {
            if !inactiveWorkspacePendingSnapshots.isEmpty {
                enterDeferredEnvironmentWait(requiresActiveSpaceChange: true)
                lock.unlock()
                return
            }

            logger.info("Restore cycle completed with no pending snapshots")
            clearRestoreState()
            lock.unlock()
            return
        }

        let timedOut: Bool
        if isWaitingForDeferredSpaceExposure {
            timedOut = false
        } else if let restoreDeadline {
            timedOut = Date() >= restoreDeadline
        } else {
            timedOut = true
        }

        // Keep retrying until displays are ready; timeout prevents indefinite waiting.
        let ready = readinessChecker.isReady(toRestore: snapshots)
        logger.debug(
            "Restore attempt check: ready=\(ready, privacy: .public) timedOut=\(timedOut, privacy: .public) deferredSpaceWait=\(self.isWaitingForDeferredSpaceExposure, privacy: .public) activeSnapshots=\(snapshots.count, privacy: .public) inactiveWorkspaceSnapshots=\(self.inactiveWorkspacePendingSnapshots.count, privacy: .public)"
        )

        if !ready && !timedOut {
            if isWaitingForDeferredSpaceExposure {
                logger.debug(
                    "Displays not ready while waiting for deferred-space windows; parking until next environment change"
                )
                restoreTask = nil
            } else {
                logger.debug(
                    "Displays not ready; retrying in \(self.retryInterval, privacy: .public)s"
                )
                scheduleRestoreAttempt(after: retryInterval)
            }
            lock.unlock()
            return
        }

        lock.unlock()
        let restoreResult = restoring.restore(from: snapshots)
        logger.info(
            "Restore invocation finished with complete=\(restoreResult.isComplete, privacy: .public) moved=\(restoreResult.movedWindowCount, privacy: .public) aligned=\(restoreResult.alreadyAlignedCount, privacy: .public) failures=\(restoreResult.recoverableFailureCount, privacy: .public) deferred=\(restoreResult.deferredSnapshotCount, privacy: .public) deferredInactiveWorkspace=\(restoreResult.deferredInactiveWorkspaceSnapshots.count, privacy: .public)"
        )

        lock.lock()
        guard !isSleeping, isAwaitingPostWakeRestore else {
            logger.debug("Discarding restore result because state changed during restore execution")
            lock.unlock()
            return
        }

        let normalizedResolvedSnapshots: [WindowSnapshot]
        if restoreResult.isComplete, restoreResult.resolvedSnapshots.isEmpty {
            // Backward-compatibility path for restore implementations that still
            // signal completion without providing explicit resolved snapshots.
            normalizedResolvedSnapshots = snapshots
        } else {
            normalizedResolvedSnapshots = restoreResult.resolvedSnapshots
        }
        let unresolvedAttemptSnapshots = SnapshotSetOperations.removeResolved(
            from: snapshots,
            resolved: normalizedResolvedSnapshots
        )

        if restoreResult.movedWindowCount > 0 || restoreResult.alreadyAlignedCount > 0 {
            hasObservedPlacementProgress = true
        }

        if isWaitingForDeferredSpaceExposure,
            restoreResult.recoverableFailureCount != restoreResult.deferredSnapshotCount
        {
            logger.debug("Exiting deferred-space wait mode due to non-deferred residual failures")
            isWaitingForDeferredSpaceExposure = false
            requiresActiveSpaceChangeForDeferredRestore = false
        }

        if !normalizedResolvedSnapshots.isEmpty {
            let priorPendingCount = pendingRestoreSnapshots.count
            pendingRestoreSnapshots = SnapshotSetOperations.removeResolved(
                from: pendingRestoreSnapshots,
                resolved: normalizedResolvedSnapshots
            )
            inactiveWorkspacePendingSnapshots = SnapshotSetOperations.removeResolved(
                from: inactiveWorkspacePendingSnapshots,
                resolved: normalizedResolvedSnapshots
            )
            logger.debug(
                "Pruned resolved snapshots from pending set (resolved=\(normalizedResolvedSnapshots.count, privacy: .public) pendingBefore=\(priorPendingCount, privacy: .public) pendingAfter=\(self.pendingRestoreSnapshots.count, privacy: .public))"
            )
        }

        if !restoreResult.deferredInactiveWorkspaceSnapshots.isEmpty {
            let movedToInactiveCount = appendInactiveWorkspacePendingSnapshots(
                restoreResult.deferredInactiveWorkspaceSnapshots,
                allowedFrom: unresolvedAttemptSnapshots
            )
            if movedToInactiveCount > 0 {
                logger.debug(
                    "Moved \(movedToInactiveCount, privacy: .public) snapshot(s) into inactive-workspace pending set (active=\(self.activeWorkspacePendingSnapshots().count, privacy: .public) inactive=\(self.inactiveWorkspacePendingSnapshots.count, privacy: .public))"
                )
            }
        }

        if pendingRestoreSnapshots.isEmpty {
            logger.info("Restore cycle completed after pruning all pending snapshots")
            clearRestoreState()
            lock.unlock()
            return
        }

        if activeWorkspacePendingSnapshots().isEmpty && !inactiveWorkspacePendingSnapshots.isEmpty {
            enterDeferredEnvironmentWait(requiresActiveSpaceChange: true)
            lock.unlock()
            return
        }

        if isWaitingForDeferredSpaceExposure,
            shouldWaitForEnvironmentForDeferredResiduals(restoreResult)
        {
            enterDeferredEnvironmentWait(
                requiresActiveSpaceChange: requiresActiveSpaceChangeForDeferredRestore)
            lock.unlock()
            return
        }

        if timedOut {
            let madeObservableProgress =
                !normalizedResolvedSnapshots.isEmpty
                || restoreResult.movedWindowCount > 0
                || restoreResult.alreadyAlignedCount > 0

            if shouldWaitForEnvironmentForDeferredResiduals(restoreResult)
                || restoreResult.deferredSnapshotCount > 0
            {
                enterDeferredEnvironmentWait(
                    requiresActiveSpaceChange: hasInactiveWorkspacePendingSnapshots())
                lock.unlock()
                return
            }

            if madeObservableProgress {
                postTimeoutRetryCount = 0
                logger.warning(
                    "Restore made progress after timeout; waiting for environment change before retry"
                )
                restoreTask = nil
                restoreDeadline = nil
                lock.unlock()
                return
            }

            postTimeoutRetryCount += 1
            if postTimeoutRetryCount >= maxPostTimeoutEnvironmentRetries {
                logger.warning(
                    "Restore failed after timeout \(self.postTimeoutRetryCount, privacy: .public) time(s); ending wake restore cycle"
                )
                clearRestoreState()
                lock.unlock()
                return
            }

            // Do not spin forever after timeout. Wait for a concrete environment change
            // signal (for example, session became active after unlock) to retry.
            logger.warning(
                "Restore failed after timeout; waiting for environment change signal before retry (\(self.postTimeoutRetryCount, privacy: .public)/\(self.maxPostTimeoutEnvironmentRetries, privacy: .public))"
            )
            restoreTask = nil
            restoreDeadline = nil
            lock.unlock()
            return
        }

        if noteStagnationAndShouldWaitForEnvironment(restoreResult) {
            if shouldWaitForEnvironmentForDeferredResiduals(restoreResult) {
                enterDeferredEnvironmentWait(
                    requiresActiveSpaceChange: hasInactiveWorkspacePendingSnapshots())
                lock.unlock()
                return
            }

            // Convert repeated no-progress retries into explicit environment-triggered
            // retries to avoid thrashing windows every retry interval.
            restoreTask = nil
            restoreDeadline = Date()
            logger.warning(
                "Restore made no progress for \(self.stagnantRestoreAttemptCount, privacy: .public) attempt(s); waiting for environment change before retry"
            )
            lock.unlock()
            return
        }

        logger.warning(
            "Restore failed before timeout; retrying in \(self.retryInterval, privacy: .public)s"
        )
        scheduleRestoreAttempt(after: retryInterval)
        lock.unlock()
    }

    private func activeWorkspacePendingSnapshots() -> [WindowSnapshot] {
        SnapshotSetOperations.removeResolved(
            from: pendingRestoreSnapshots,
            resolved: inactiveWorkspacePendingSnapshots
        )
    }

    private func hasInactiveWorkspacePendingSnapshots() -> Bool {
        !inactiveWorkspacePendingSnapshots.isEmpty
    }

    private func promoteInactiveWorkspaceSnapshotsToActive() -> Int {
        let promotedCount = inactiveWorkspacePendingSnapshots.count
        inactiveWorkspacePendingSnapshots = []
        return promotedCount
    }

    private func appendInactiveWorkspacePendingSnapshots(
        _ snapshots: [WindowSnapshot],
        allowedFrom source: [WindowSnapshot]
    ) -> Int {
        guard !snapshots.isEmpty, !source.isEmpty else {
            return 0
        }

        var remainingBySnapshot: [WindowSnapshot: Int] = [:]
        for snapshot in source {
            remainingBySnapshot[snapshot, default: 0] += 1
        }

        var appended: [WindowSnapshot] = []
        appended.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            let remaining = remainingBySnapshot[snapshot] ?? 0
            guard remaining > 0 else {
                continue
            }
            remainingBySnapshot[snapshot] = remaining - 1
            appended.append(snapshot)
        }

        guard !appended.isEmpty else {
            return 0
        }

        inactiveWorkspacePendingSnapshots.append(contentsOf: appended)
        return appended.count
    }

    private func clearRestoreState() {
        logger.debug("Clearing post-wake restore state")
        restoreTask?.cancel()
        restoreTask = nil
        pendingRestoreSnapshots = []
        inactiveWorkspacePendingSnapshots = []
        isAwaitingPostWakeRestore = false
        restoreDeadline = nil
        resetRestoreAttemptTracking()
        clearDeferredExposureWait()
    }

    private func resetRestoreAttemptTracking() {
        stagnantRestoreAttemptCount = 0
        bestRecoverableFailureCount = nil
        postTimeoutRetryCount = 0
        hasObservedPlacementProgress = false
        lastIncompleteRestoreResult = nil
    }

    private func clearDeferredExposureWait() {
        isWaitingForDeferredSpaceExposure = false
        requiresActiveSpaceChangeForDeferredRestore = false
    }

    private func noteStagnationAndShouldWaitForEnvironment(_ result: WindowRestoreResult) -> Bool {
        // Treat retries as equivalent when unresolved state is unchanged, even if
        // movedWindowCount jitters; a single window can "move" repeatedly without
        // reducing recoverable failures.
        let repeatedResidualState: Bool
        if let lastIncompleteRestoreResult {
            repeatedResidualState =
                lastIncompleteRestoreResult.recoverableFailureCount
                == result.recoverableFailureCount
                && lastIncompleteRestoreResult.deferredSnapshotCount == result.deferredSnapshotCount
                && lastIncompleteRestoreResult.alreadyAlignedCount == result.alreadyAlignedCount
        } else {
            repeatedResidualState = false
        }
        defer {
            lastIncompleteRestoreResult = result
        }

        if result.deferredSnapshotCount > 0, !hasObservedPlacementProgress {
            // Deferred snapshots indicate the app has not exposed all windows yet.
            // Before any placement progress, keep retrying on interval rather than
            // parking on environment changes.
            stagnantRestoreAttemptCount = 0
            if let bestRecoverableFailureCount {
                self.bestRecoverableFailureCount = min(
                    bestRecoverableFailureCount, result.recoverableFailureCount)
            } else {
                bestRecoverableFailureCount = result.recoverableFailureCount
            }
            return false
        }

        let improvedFailureCount: Bool
        if let bestRecoverableFailureCount {
            improvedFailureCount = result.recoverableFailureCount < bestRecoverableFailureCount
        } else {
            improvedFailureCount = true
        }

        if improvedFailureCount {
            bestRecoverableFailureCount = result.recoverableFailureCount
            stagnantRestoreAttemptCount = 0
            return false
        }

        if result.movedWindowCount > 0 {
            // A single window can report as moved repeatedly without net progress
            // (for example, app immediately repositions it). Detect repeated
            // unresolved outcomes so this does not create infinite retry loops.
            if repeatedResidualState,
                result.recoverableFailureCount == result.deferredSnapshotCount,
                result.alreadyAlignedCount > 0
            {
                stagnantRestoreAttemptCount += 1
                logger.debug(
                    "Stagnation count incremented for unresolved deferred-only residuals (\(self.stagnantRestoreAttemptCount, privacy: .public)/\(self.maxStagnantAttemptsBeforeEnvironmentWait, privacy: .public)); moved=\(result.movedWindowCount, privacy: .public) aligned=\(result.alreadyAlignedCount, privacy: .public) failures=\(result.recoverableFailureCount, privacy: .public) deferred=\(result.deferredSnapshotCount, privacy: .public)"
                )
                return stagnantRestoreAttemptCount >= maxStagnantAttemptsBeforeEnvironmentWait
            }
            stagnantRestoreAttemptCount = 0
            return false
        }

        // If recoverable failures are unchanged and nothing moved, repeated retries
        // are unlikely to help until the environment changes again.
        stagnantRestoreAttemptCount += 1
        return stagnantRestoreAttemptCount >= maxStagnantAttemptsBeforeEnvironmentWait
    }

    private func shouldWaitForEnvironmentForDeferredResiduals(_ result: WindowRestoreResult)
        -> Bool
    {
        guard hasObservedPlacementProgress else {
            return false
        }

        guard result.recoverableFailureCount > 0 else {
            return false
        }

        return result.recoverableFailureCount == result.deferredSnapshotCount
    }

    private func enterDeferredEnvironmentWait(requiresActiveSpaceChange: Bool) {
        if !isWaitingForDeferredSpaceExposure {
            logger.info(
                "Restore has deferred-only residual windows; waiting for environment change (for example, active space switch)"
            )
        } else {
            logger.debug("Still waiting for deferred-space windows; no interval retry scheduled")
        }

        isWaitingForDeferredSpaceExposure = true
        requiresActiveSpaceChangeForDeferredRestore = requiresActiveSpaceChange
        restoreTask = nil
        restoreDeadline = nil
        stagnantRestoreAttemptCount = 0
        postTimeoutRetryCount = 0
        lastIncompleteRestoreResult = nil
    }

}
