import Foundation

// Design goal: keep coordinator logic testable by depending on narrow protocols.
public protocol WindowSnapshotCapturing {
    func capture() -> [WindowSnapshot]
}

public struct WindowRestoreResult: Equatable, Sendable {
    public var isComplete: Bool
    public var movedWindowCount: Int
    public var alreadyAlignedCount: Int
    public var recoverableFailureCount: Int
    public var deferredSnapshotCount: Int

    public init(
        isComplete: Bool,
        movedWindowCount: Int = 0,
        alreadyAlignedCount: Int = 0,
        recoverableFailureCount: Int = 0,
        deferredSnapshotCount: Int = 0
    ) {
        self.isComplete = isComplete
        self.movedWindowCount = movedWindowCount
        self.alreadyAlignedCount = alreadyAlignedCount
        self.recoverableFailureCount = recoverableFailureCount
        self.deferredSnapshotCount = deferredSnapshotCount
    }

    public static let successfulNoop = WindowRestoreResult(
        isComplete: true,
        movedWindowCount: 0,
        alreadyAlignedCount: 0,
        recoverableFailureCount: 0,
        deferredSnapshotCount: 0
    )
}

public protocol WindowSnapshotRestoring {
    // Design goal: expose enough detail for coordinator convergence logic
    // (progress/stagnation) instead of a binary success/fail signal.
    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult
}

public protocol SnapshotRepository {
    func load() -> [WindowSnapshot]
    func save(_ snapshots: [WindowSnapshot])
}

public protocol RestoreReadinessChecking {
    func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool
}

public struct ImmediateRestoreReadinessChecker: RestoreReadinessChecking {
    public init() {}

    public func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool {
        true
    }
}

public protocol CancellableTask {
    func cancel()
}

public protocol SleepWakeScheduling {
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CancellableTask
}
