import Dispatch
import Foundation

// Design goal: make timing behavior swappable so retries can be unit-tested.
public final class DispatchScheduler: SleepWakeScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void)
        -> CancellableTask
    {
        let item = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchCancellable(item: item)
    }
}

private final class DispatchCancellable: CancellableTask {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}
