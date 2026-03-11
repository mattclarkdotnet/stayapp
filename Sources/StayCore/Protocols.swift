import Foundation

// Design goal: keep coordinator logic testable by depending on narrow protocols.
/// Captures the current window layout as restorable snapshots.
public protocol WindowSnapshotCapturing {
    /// Returns the currently captured window snapshots.
    func capture() -> [WindowSnapshot]
}

/// Structured restore outcome used by retry and convergence logic.
public struct WindowRestoreResult: Equatable, Sendable {
    /// `true` when no additional retries are required.
    public var isComplete: Bool
    /// Number of windows that were moved this restore attempt.
    public var movedWindowCount: Int
    /// Number of windows already aligned with target state.
    public var alreadyAlignedCount: Int
    /// Number of recoverable windows that still failed this attempt.
    public var recoverableFailureCount: Int
    /// Number of failures deferred because windows are not currently exposable.
    public var deferredSnapshotCount: Int
    // Snapshots that are now resolved (aligned or moved+converged) and should be
    // removed from subsequent retry attempts in the same wake cycle.
    /// Snapshots resolved in this attempt and removable from pending retries.
    public var resolvedSnapshots: [WindowSnapshot]

    /// Creates a restore result with explicit progress counts.
    public init(
        isComplete: Bool,
        movedWindowCount: Int = 0,
        alreadyAlignedCount: Int = 0,
        recoverableFailureCount: Int = 0,
        deferredSnapshotCount: Int = 0,
        resolvedSnapshots: [WindowSnapshot] = []
    ) {
        self.isComplete = isComplete
        self.movedWindowCount = movedWindowCount
        self.alreadyAlignedCount = alreadyAlignedCount
        self.recoverableFailureCount = recoverableFailureCount
        self.deferredSnapshotCount = deferredSnapshotCount
        self.resolvedSnapshots = resolvedSnapshots
    }

    /// Successful restore with no movement needed.
    public static let successfulNoop = WindowRestoreResult(
        isComplete: true,
        movedWindowCount: 0,
        alreadyAlignedCount: 0,
        recoverableFailureCount: 0,
        deferredSnapshotCount: 0,
        resolvedSnapshots: []
    )
}

/// Applies a snapshot set to live windows and reports structured progress.
public protocol WindowSnapshotRestoring {
    // Design goal: expose enough detail for coordinator convergence logic
    // (progress/stagnation) instead of a binary success/fail signal.
    /// Attempts to restore the provided snapshots.
    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult
}

/// Durable storage for persisted snapshots across sleep/wake cycles.
public protocol SnapshotRepository {
    /// Loads persisted snapshots.
    func load() -> [WindowSnapshot]
    /// Persists snapshots for future wake cycles.
    func save(_ snapshots: [WindowSnapshot])
}

/// Readiness gate used before attempting restore.
public protocol RestoreReadinessChecking {
    /// Returns whether the environment is currently ready for restore.
    func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool
}

/// Readiness checker used when no display gating is required.
public struct ImmediateRestoreReadinessChecker: RestoreReadinessChecking {
    /// Creates an always-ready checker.
    public init() {}

    /// Always returns `true`.
    public func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool {
        true
    }
}

/// Handle for a scheduled restore task.
public protocol CancellableTask {
    /// Cancels the scheduled task.
    func cancel()
}

/// Scheduler abstraction used by the coordinator for delayed retries.
public protocol SleepWakeScheduling {
    /// Schedules `action` to run after `delay`.
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CancellableTask
}
