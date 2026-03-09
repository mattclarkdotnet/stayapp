import Foundation
import OSLog

// Design goal: deterministic, resilient sleep/wake handling that tolerates
// repeated or out-of-order events and delays restore until conditions are safe.
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
    private var isSleeping = false
    private var cachedSnapshots: [WindowSnapshot] = []
    private var pendingRestoreSnapshots: [WindowSnapshot] = []
    private var isAwaitingPostWakeRestore = false
    private var restoreDeadline: Date?
    private var restoreTask: CancellableTask?
    private var stagnantRestoreAttemptCount = 0
    private var bestRecoverableFailureCount: Int?
    private var postTimeoutRetryCount = 0
    private var hasObservedPlacementProgress = false
    private var lastIncompleteRestoreResult: WindowRestoreResult?

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

    public func handleWillSleep() {
        // Capture as late as possible before sleep and cancel any pending restore.
        let latestSnapshots = capturing.capture()
        let persistedSnapshots = repository.load()
        let snapshots = mergedSnapshots(latest: latestSnapshots, fallback: persistedSnapshots)

        logger.info(
            "Received willSleep; latest=\(latestSnapshots.count, privacy: .public) persisted=\(persistedSnapshots.count, privacy: .public) merged=\(snapshots.count, privacy: .public)"
        )

        lock.lock()
        restoreTask?.cancel()
        restoreTask = nil
        isAwaitingPostWakeRestore = false
        pendingRestoreSnapshots = []
        restoreDeadline = nil
        stagnantRestoreAttemptCount = 0
        bestRecoverableFailureCount = nil
        postTimeoutRetryCount = 0
        hasObservedPlacementProgress = false
        lastIncompleteRestoreResult = nil
        if !snapshots.isEmpty {
            cachedSnapshots = snapshots
        }
        isSleeping = true
        lock.unlock()

        if !snapshots.isEmpty {
            repository.save(snapshots)
            logger.info("Persisted \(snapshots.count, privacy: .public) snapshot(s)")
        } else {
            logger.warning("No snapshots captured during willSleep")
        }
    }

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
            isAwaitingPostWakeRestore = false
            pendingRestoreSnapshots = []
            restoreDeadline = nil
            lock.unlock()
            return
        }

        isAwaitingPostWakeRestore = true
        pendingRestoreSnapshots = snapshots
        restoreDeadline = Date().addingTimeInterval(maxWaitAfterWake)
        stagnantRestoreAttemptCount = 0
        bestRecoverableFailureCount = nil
        postTimeoutRetryCount = 0
        hasObservedPlacementProgress = false
        lastIncompleteRestoreResult = nil
        if let restoreDeadline {
            logger.info(
                "Wake cycle started; awaiting restore for \(snapshots.count, privacy: .public) snapshot(s) with deadline \(restoreDeadline.ISO8601Format(), privacy: .public)"
            )
        }
        scheduleRestoreAttempt(after: wakeDelay)
        lock.unlock()
    }

    public func handleEnvironmentDidChange() {
        lock.lock()
        guard !isSleeping, isAwaitingPostWakeRestore else {
            lock.unlock()
            return
        }

        // Environment signals (screens/session/workspace) are strong indicators
        // that windows are now accessible after wake or unlock.
        logger.debug("Environment change signal received; scheduling immediate restore attempt")
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

        let snapshots = pendingRestoreSnapshots
        let deadline = restoreDeadline ?? Date()

        // Keep retrying until displays are ready; timeout prevents indefinite waiting.
        let timedOut = Date() >= deadline
        let ready = readinessChecker.isReady(toRestore: snapshots)
        logger.debug(
            "Restore attempt check: ready=\(ready, privacy: .public) timedOut=\(timedOut, privacy: .public) snapshots=\(snapshots.count, privacy: .public)"
        )

        if !ready && !timedOut {
            logger.debug(
                "Displays not ready; retrying in \(self.retryInterval, privacy: .public)s"
            )
            scheduleRestoreAttempt(after: retryInterval)
            lock.unlock()
            return
        }

        lock.unlock()
        let restoreResult = restoring.restore(from: snapshots)
        logger.info(
            "Restore invocation finished with complete=\(restoreResult.isComplete, privacy: .public) moved=\(restoreResult.movedWindowCount, privacy: .public) aligned=\(restoreResult.alreadyAlignedCount, privacy: .public) failures=\(restoreResult.recoverableFailureCount, privacy: .public) deferred=\(restoreResult.deferredSnapshotCount, privacy: .public)"
        )

        lock.lock()
        guard !isSleeping, isAwaitingPostWakeRestore else {
            logger.debug("Discarding restore result because state changed during restore execution")
            lock.unlock()
            return
        }

        if restoreResult.isComplete {
            logger.info("Restore cycle completed successfully")
            clearRestoreState()
            lock.unlock()
            return
        }

        if restoreResult.movedWindowCount > 0 || restoreResult.alreadyAlignedCount > 0 {
            hasObservedPlacementProgress = true
        }

        if !restoreResult.resolvedSnapshots.isEmpty {
            let priorPendingCount = pendingRestoreSnapshots.count
            pendingRestoreSnapshots = removingResolvedSnapshots(
                from: pendingRestoreSnapshots,
                resolved: restoreResult.resolvedSnapshots
            )
            logger.debug(
                "Pruned resolved snapshots from pending set (resolved=\(restoreResult.resolvedSnapshots.count, privacy: .public) pendingBefore=\(priorPendingCount, privacy: .public) pendingAfter=\(self.pendingRestoreSnapshots.count, privacy: .public))"
            )

            if pendingRestoreSnapshots.isEmpty {
                logger.info("Restore cycle completed after pruning all pending snapshots")
                clearRestoreState()
                lock.unlock()
                return
            }
        }

        if timedOut {
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
            if shouldConcludeWithDeferredResiduals(restoreResult) {
                logger.info(
                    "Restore converged with deferred-only residual windows; ending wake restore cycle"
                )
                clearRestoreState()
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

    private func clearRestoreState() {
        logger.debug("Clearing post-wake restore state")
        restoreTask?.cancel()
        restoreTask = nil
        pendingRestoreSnapshots = []
        isAwaitingPostWakeRestore = false
        restoreDeadline = nil
        stagnantRestoreAttemptCount = 0
        bestRecoverableFailureCount = nil
        postTimeoutRetryCount = 0
        hasObservedPlacementProgress = false
        lastIncompleteRestoreResult = nil
    }

    private func noteStagnationAndShouldWaitForEnvironment(_ result: WindowRestoreResult) -> Bool {
        // Treat retries as equivalent when unresolved state is unchanged, even if
        // movedWindowCount jitters; a single window can "move" repeatedly without
        // reducing recoverable failures.
        let repeatedResidualState: Bool
        if let lastIncompleteRestoreResult {
            repeatedResidualState =
                lastIncompleteRestoreResult.recoverableFailureCount == result.recoverableFailureCount
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

    private func shouldConcludeWithDeferredResiduals(_ result: WindowRestoreResult) -> Bool {
        guard hasObservedPlacementProgress else {
            return false
        }

        guard result.alreadyAlignedCount > 0 else {
            return false
        }

        guard result.recoverableFailureCount > 0 else {
            return false
        }

        return result.recoverableFailureCount == result.deferredSnapshotCount
    }

    private func removingResolvedSnapshots(
        from pending: [WindowSnapshot],
        resolved: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        guard !pending.isEmpty, !resolved.isEmpty else {
            return pending
        }

        var pendingRemovalCountBySnapshot: [WindowSnapshot: Int] = [:]
        for snapshot in resolved {
            pendingRemovalCountBySnapshot[snapshot, default: 0] += 1
        }

        var filtered: [WindowSnapshot] = []
        filtered.reserveCapacity(pending.count)

        for snapshot in pending {
            let pendingRemovalCount = pendingRemovalCountBySnapshot[snapshot] ?? 0
            if pendingRemovalCount > 0 {
                pendingRemovalCountBySnapshot[snapshot] = pendingRemovalCount - 1
            } else {
                filtered.append(snapshot)
            }
        }

        return filtered
    }

    private func mergedSnapshots(latest: [WindowSnapshot], fallback: [WindowSnapshot])
        -> [WindowSnapshot]
    {
        guard !latest.isEmpty else {
            return fallback
        }

        guard !fallback.isEmpty else {
            return latest
        }

        let latestByApp = Dictionary(grouping: latest, by: appIdentity)
        let fallbackByApp = Dictionary(grouping: fallback, by: appIdentity)

        let allKeys = Set(latestByApp.keys).union(fallbackByApp.keys).sorted()
        var merged: [WindowSnapshot] = []
        merged.reserveCapacity(max(latest.count, fallback.count))

        for key in allKeys {
            let latestForApp = latestByApp[key] ?? []
            let fallbackForApp = fallbackByApp[key] ?? []
            // Prefer latest per-app snapshots whenever that app was seen at willSleep.
            // Only fall back to persisted snapshots for apps missing entirely from latest.
            if !latestForApp.isEmpty {
                merged.append(contentsOf: latestForApp)
            } else if !fallbackForApp.isEmpty {
                merged.append(contentsOf: fallbackForApp)
            }
        }

        return merged
    }

    private func appIdentity(for snapshot: WindowSnapshot) -> String {
        if let bundleID = snapshot.appBundleID, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "pid:\(snapshot.appPID)"
    }
}
