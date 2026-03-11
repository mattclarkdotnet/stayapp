import Foundation
import Testing

@testable import StayCore

@Suite("SleepWakeCoordinator")
struct SleepWakeCoordinatorTests {
    @Test("Wake before sleep is ignored")
    func wakeBeforeSleepIsIgnored() {
        let capture = StubCaptureService()
        capture.nextSnapshots = [sampleSnapshot(title: "One", index: 0)]

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 1
        )

        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(restore.calls.isEmpty)
        #expect(capture.captureCount == 0)
    }

    @Test("Will sleep captures and persists snapshots")
    func willSleepCapturesAndPersistsSnapshots() {
        let snapshots = [sampleSnapshot(title: "Safari", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 1
        )

        coordinator.handleWillSleep()

        #expect(capture.captureCount == 1)
        #expect(repository.saved == snapshots)
        #expect(restore.calls.isEmpty)
    }

    @Test("Repeated wake events schedule only one restore")
    func repeatedWakeEventsScheduleOnlyOneRestore() {
        let snapshots = [sampleSnapshot(title: "Mail", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        coordinator.handleDidWake()

        #expect(scheduler.pendingCount == 1)

        scheduler.runAll()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == snapshots)
    }

    @Test("New sleep cycle cancels pending restore")
    func newSleepCycleCancelsPendingRestore() {
        let first = [sampleSnapshot(title: "Xcode", index: 0)]
        let second = [sampleSnapshot(title: "Terminal", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = first

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        capture.nextSnapshots = second
        coordinator.handleWillSleep()

        scheduler.runAll()
        #expect(restore.calls.isEmpty)

        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == second)
    }

    @Test("Stored snapshots are used when capture fails")
    func storedSnapshotsAreUsedWhenCaptureFails() {
        let stored = [sampleSnapshot(title: "Notes", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = []

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        repository.saved = stored

        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == stored)
        #expect(repository.loadCount == 1)
    }

    @Test("Empty capture+repository clears stale cached snapshots for next wake")
    func emptyCaptureAndRepositoryClearsStaleCachedSnapshots() {
        let stale = [sampleSnapshot(title: "Stale", index: 0)]

        let capture = StubCaptureService()
        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 0
        )

        // First cycle caches and restores a valid snapshot.
        capture.nextSnapshots = stale
        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runAll()
        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == stale)

        // Second cycle has no capture data and no persisted fallback.
        capture.nextSnapshots = []
        repository.saved = []
        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runAll()

        // No second restore should occur; stale cache must not leak across cycles.
        #expect(restore.calls.count == 1)
    }

    @Test("Explicitly empty app identities suppress stale fallback snapshots")
    func explicitlyEmptyAppIdentitiesSuppressStaleFallbackSnapshots() {
        let finder = sampleSnapshot(
            pid: 101,
            bundleID: "com.apple.finder",
            appName: "Finder",
            title: "Finder Window",
            index: 0
        )
        let staleGhostty = sampleSnapshot(
            pid: 202,
            bundleID: "com.mitchellh.ghostty",
            appName: "Ghostty",
            title: "Ghostty Window",
            index: 0
        )

        let capture = StubCaptureService()
        capture.nextSnapshots = [finder]
        capture.explicitlyEmptyAppIdentities = ["bundle:com.mitchellh.ghostty"]

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        repository.saved = [finder, staleGhostty]
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 0
        )

        coordinator.handleWillSleep()
        #expect(repository.saved == [finder])

        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == [finder])
    }

    @Test("Restore waits until readiness checker reports ready")
    func restoreWaitsUntilReady() {
        let snapshots = [sampleSnapshot(title: "Chrome", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([false, false, true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0.1,
            retryInterval: 0.1,
            maxWaitAfterWake: 5
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.isEmpty)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.isEmpty)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == snapshots)
    }

    @Test("Restore proceeds after timeout when readiness never arrives")
    func restoreProceedsAfterTimeout() {
        let snapshots = [sampleSnapshot(title: "Keynote", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([false, false, false])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.2,
            maxWaitAfterWake: -1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runNext()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == snapshots)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Restore retries when restore service reports failure")
    func restoreRetriesWhenRestoreFails() {
        let snapshots = [sampleSnapshot(title: "Safari", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.results = [false, true]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 5
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runNext()

        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Stagnant pre-timeout failures wait for environment change before retry")
    func stagnantFailuresWaitForEnvironmentChange() {
        let snapshots = [sampleSnapshot(title: "Safari", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 1,
                recoverableFailureCount: 3
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 1,
                recoverableFailureCount: 3
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 1,
                recoverableFailureCount: 3
            ),
            WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120,
            maxStagnantAttemptsBeforeEnvironmentWait: 2
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 4)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Deferred snapshots bypass stagnation wait and continue retrying")
    func deferredSnapshotsBypassStagnationWait() {
        let snapshots = [sampleSnapshot(title: "FreeCAD", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120,
            maxStagnantAttemptsBeforeEnvironmentWait: 1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Deferred-only residuals park for environment change after stagnation")
    func deferredResidualsConcludeWakeCycle() {
        let snapshots = [sampleSnapshot(title: "FreeCAD", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 2,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 3,
                deferredSnapshotCount: 3
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 3,
                deferredSnapshotCount: 3
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 3,
                deferredSnapshotCount: 3
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120,
            maxStagnantAttemptsBeforeEnvironmentWait: 2
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        #expect(scheduler.pendingCount == 1)
        scheduler.runNext()
        #expect(restore.calls.count == 4)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Resolved snapshots are pruned from later retry attempts")
    func resolvedSnapshotsArePrunedAcrossRetries() {
        let first = sampleSnapshot(title: "One", index: 0)
        let second = sampleSnapshot(title: "Two", index: 1)
        let third = sampleSnapshot(title: "Three", index: 2)
        let snapshots = [first, second, third]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 2,
                deferredSnapshotCount: 0,
                resolvedSnapshots: [first]
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 1,
                deferredSnapshotCount: 0,
                resolvedSnapshots: [second]
            ),
            WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0,
                resolvedSnapshots: [third]
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(restore.calls[0] == snapshots)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(restore.calls[1].count == 2)
        #expect(!restore.calls[1].contains(first))
        #expect(restore.calls[1].contains(second))
        #expect(restore.calls[1].contains(third))
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(restore.calls[2] == [third])
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Repeated moved deferred residuals park and retry on environment change")
    func repeatedMovedDeferredResidualsConverge() {
        let snapshots = [sampleSnapshot(title: "Finder", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120,
            maxStagnantAttemptsBeforeEnvironmentWait: 2
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        #expect(scheduler.pendingCount == 1)
        scheduler.runNext()
        #expect(restore.calls.count == 4)
        #expect(scheduler.pendingCount == 0)
    }

    @Test(
        "Moved-count jitter with unchanged residual state parks then retries on environment change")
    func movedCountJitterConverges() {
        let snapshots = [sampleSnapshot(title: "Finder", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 5,
                alreadyAlignedCount: 1,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 2,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 1,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 3,
                alreadyAlignedCount: 5,
                recoverableFailureCount: 4,
                deferredSnapshotCount: 4
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: 120,
            maxStagnantAttemptsBeforeEnvironmentWait: 2
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 3)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 4)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        #expect(scheduler.pendingCount == 1)
        scheduler.runNext()
        #expect(restore.calls.count == 5)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Environment change retriggers restore after timeout")
    func environmentChangeRetriggersRestoreAfterTimeout() {
        let snapshots = [sampleSnapshot(title: "Safari", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.results = [false, true]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([false, false, false])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: -1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runNext()

        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange()
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
    }

    @Test("Deferred post-timeout retries wait for active-space changes")
    func deferredTimeoutRetriesRequireActiveSpaceChange() {
        let snapshots = [sampleSnapshot(title: "FreeCAD", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.detailedResults = [
            WindowRestoreResult(
                isComplete: false,
                movedWindowCount: 0,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 1,
                deferredSnapshotCount: 1
            ),
            WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0
            ),
        ]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([true])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: -1
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runNext()

        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.sessionDidBecomeActive)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.screensDidWake)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 0)
    }

    @Test("Post-timeout retries are capped to avoid infinite environment-change loops")
    func postTimeoutRetriesAreCapped() {
        let snapshots = [sampleSnapshot(title: "Safari", index: 0)]

        let capture = StubCaptureService()
        capture.nextSnapshots = snapshots

        let restore = SpyRestoreService()
        restore.results = [false, false, false]

        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = SequencedReadinessChecker([false, false, false, false])

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0.1,
            maxWaitAfterWake: -1,
            maxPostTimeoutEnvironmentRetries: 2
        )

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        scheduler.runNext()
        #expect(restore.calls.count == 1)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange()
        #expect(scheduler.pendingCount == 1)
        scheduler.runNext()
        #expect(restore.calls.count == 2)
        #expect(scheduler.pendingCount == 0)

        coordinator.handleEnvironmentDidChange()
        #expect(scheduler.pendingCount == 0)
        #expect(restore.calls.count == 2)
    }

    @Test("WillSleep merges partial capture with persisted snapshots")
    func willSleepMergesPartialCaptureWithPersistedSnapshots() {
        let latest = [
            sampleSnapshot(pid: 111, bundleID: "com.apple.Finder", title: "Desktop", index: 0)
        ]
        let persisted = [
            sampleSnapshot(pid: 111, bundleID: "com.apple.Finder", title: "Desktop", index: 0),
            sampleSnapshot(pid: 222, bundleID: "com.apple.Safari", title: "OpenAI", index: 0),
        ]

        let capture = StubCaptureService()
        capture.nextSnapshots = latest

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        repository.saved = persisted
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 0
        )

        coordinator.handleWillSleep()
        #expect(repository.saved.count == 2)

        coordinator.handleDidWake()
        scheduler.runAll()

        #expect(restore.calls.count == 1)
        #expect(restore.calls[0].count == 2)
    }

    @Test("WillSleep prefers latest app snapshots over larger persisted app sets")
    func willSleepPrefersLatestNonEmptyAppSnapshots() {
        let latest = [
            sampleSnapshot(
                pid: 111, bundleID: "com.apple.Finder", title: "Current Finder", index: 0)
        ]
        let persisted = [
            sampleSnapshot(
                pid: 111, bundleID: "com.apple.Finder", title: "Current Finder", index: 0),
            sampleSnapshot(pid: 111, bundleID: "com.apple.Finder", title: "Stale Finder", index: 1),
            sampleSnapshot(pid: 222, bundleID: "com.apple.Safari", title: "OpenAI", index: 0),
        ]

        let capture = StubCaptureService()
        capture.nextSnapshots = latest

        let restore = SpyRestoreService()
        let repository = InMemoryRepository()
        repository.saved = persisted
        let scheduler = ManualScheduler()

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            scheduler: scheduler,
            wakeDelay: 0
        )

        coordinator.handleWillSleep()

        let savedFinderTitles = repository.saved
            .filter { $0.appBundleID == "com.apple.Finder" }
            .map { $0.windowTitle ?? "" }
            .sorted()

        #expect(savedFinderTitles == ["Current Finder"])
        #expect(repository.saved.contains(where: { $0.appBundleID == "com.apple.Safari" }))
        #expect(!repository.saved.contains(where: { $0.windowTitle == "Stale Finder" }))
    }

    @Test(
        "Seeded coordinator fuzz traces preserve core invariants",
        arguments: [
            0xA11CE01, 0xA11CE02, 0xA11CE03, 0xA11CE04, 0xA11CE05, 0xA11CE06, 0xA11CE07,
            0xA11CE08, 0xA11CE09, 0xA11CE0A,
        ]
    )
    func seededCoordinatorFuzzPreservesInvariants(seed: UInt64) {
        var rng = DeterministicRandom(seed: seed)
        let capture = StubCaptureService()
        let restore = FuzzRestoreService(seed: seed ^ 0xBAD5EED)
        let repository = InMemoryRepository()
        let scheduler = ManualScheduler()
        let readiness = FuzzReadinessChecker(seed: seed ^ 0xFACE_FEED)

        let coordinator = SleepWakeCoordinator(
            capturing: capture,
            restoring: restore,
            repository: repository,
            readinessChecker: readiness,
            scheduler: scheduler,
            wakeDelay: 0,
            retryInterval: 0,
            maxWaitAfterWake: -1,
            maxStagnantAttemptsBeforeEnvironmentWait: 2,
            maxPostTimeoutEnvironmentRetries: 2
        )

        var hasSeenWillSleep = false
        var processedRestoreCallCount = 0
        var previousCallSnapshotCount: Int?
        var previousRestoreResult: WindowRestoreResult?

        func processNewRestoreCalls() {
            while processedRestoreCallCount < restore.calls.count {
                let call = restore.calls[processedRestoreCallCount]
                let result = restore.results[processedRestoreCallCount]

                #expect(hasSeenWillSleep)

                if let previousCallSnapshotCount {
                    #expect(call.count <= previousCallSnapshotCount)

                    if let previousRestoreResult, !previousRestoreResult.isComplete {
                        let expectedNextCount = max(
                            0,
                            previousCallSnapshotCount
                                - previousRestoreResult.resolvedSnapshots.count
                        )
                        #expect(call.count == expectedNextCount)
                    }
                }

                previousCallSnapshotCount = call.count
                previousRestoreResult = result
                processedRestoreCallCount += 1
            }
        }

        // Randomized external event traces with deterministic seeds.
        for _ in 0..<120 {
            let eventRoll = rng.nextInt(100)
            switch eventRoll {
            case 0..<18:
                capture.nextSnapshots = randomCaptureSnapshots(using: &rng)
                coordinator.handleWillSleep()
                hasSeenWillSleep = true
                previousCallSnapshotCount = nil
                previousRestoreResult = nil
            case 18..<34:
                coordinator.handleDidWake()
            case 34..<48:
                coordinator.handleEnvironmentDidChange(.screensDidWake)
            case 48..<62:
                coordinator.handleEnvironmentDidChange(.sessionDidBecomeActive)
            case 62..<76:
                coordinator.handleEnvironmentDidChange(.activeSpaceDidChange)
            case 76..<90:
                scheduler.runNext()
            default:
                // Bounded drain acts as fuzzed scheduler ticks.
                for _ in 0..<3 {
                    scheduler.runNext()
                }
            }

            processNewRestoreCalls()
            #expect(scheduler.livePendingCount <= 1)
            if !hasSeenWillSleep {
                #expect(restore.calls.isEmpty)
            }
        }

        // Final bounded drain: coordinator should quiesce (no queued retries).
        for _ in 0..<30 where scheduler.livePendingCount > 0 {
            scheduler.runNext()
            processNewRestoreCalls()
            #expect(scheduler.livePendingCount <= 1)
        }

        #expect(scheduler.livePendingCount == 0)
    }

    private func randomCaptureSnapshots(using rng: inout DeterministicRandom) -> [WindowSnapshot] {
        if rng.nextInt(100) < 25 {
            return []
        }

        let appPID = Int32(100 + rng.nextInt(4))
        let count = 1 + rng.nextInt(3)
        return (0..<count).map { index in
            sampleSnapshot(
                pid: appPID,
                bundleID: "com.example.fuzz.\(appPID)",
                appName: "FuzzApp\(appPID)",
                title: "fuzz-\(appPID)-\(index)",
                index: index
            )
        }
    }

    private func sampleSnapshot(
        pid: Int32 = 123,
        bundleID: String = "com.example.app",
        appName: String = "Example",
        title: String,
        index: Int
    ) -> WindowSnapshot {
        WindowSnapshot(
            appPID: pid,
            appBundleID: bundleID,
            appName: appName,
            windowTitle: title,
            windowIndex: index,
            frame: CodableRect(x: 100, y: 100, width: 1200, height: 800),
            screenDisplayID: 696_969
        )
    }
}

private final class StubCaptureService: WindowSnapshotCapturing {
    var captureCount = 0
    var nextSnapshots: [WindowSnapshot] = []
    var explicitlyEmptyAppIdentities: Set<String> = []

    func capture() -> [WindowSnapshot] {
        captureCount += 1
        return nextSnapshots
    }

    func explicitlyEmptyAppIdentitiesFromLastCapture() -> Set<String> {
        explicitlyEmptyAppIdentities
    }
}

private final class SpyRestoreService: WindowSnapshotRestoring {
    var calls: [[WindowSnapshot]] = []
    var results: [Bool] = []
    var detailedResults: [WindowRestoreResult] = []

    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult {
        calls.append(snapshots)

        if !detailedResults.isEmpty {
            return detailedResults.removeFirst()
        }

        guard !results.isEmpty else {
            return .successfulNoop
        }

        let isComplete = results.removeFirst()
        return WindowRestoreResult(
            isComplete: isComplete,
            movedWindowCount: isComplete ? 1 : 0,
            alreadyAlignedCount: 0,
            recoverableFailureCount: isComplete ? 0 : 1
        )
    }
}

private final class InMemoryRepository: SnapshotRepository {
    var saved: [WindowSnapshot] = []
    var loadCount = 0

    func load() -> [WindowSnapshot] {
        loadCount += 1
        return saved
    }

    func save(_ snapshots: [WindowSnapshot]) {
        saved = snapshots
    }
}

private final class SequencedReadinessChecker: RestoreReadinessChecking {
    private var sequence: [Bool]
    private var index = 0

    init(_ sequence: [Bool]) {
        self.sequence = sequence
    }

    func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool {
        guard !sequence.isEmpty else {
            return true
        }

        defer {
            if index < sequence.count - 1 {
                index += 1
            }
        }

        return sequence[index]
    }
}

private final class FuzzReadinessChecker: RestoreReadinessChecking {
    private var rng: DeterministicRandom

    init(seed: UInt64) {
        rng = DeterministicRandom(seed: seed)
    }

    func isReady(toRestore snapshots: [WindowSnapshot]) -> Bool {
        // Bias toward "ready" while still exercising the readiness gate.
        rng.nextInt(100) < 75
    }
}

private final class FuzzRestoreService: WindowSnapshotRestoring {
    private var rng: DeterministicRandom
    var calls: [[WindowSnapshot]] = []
    var results: [WindowRestoreResult] = []

    init(seed: UInt64) {
        rng = DeterministicRandom(seed: seed)
    }

    func restore(from snapshots: [WindowSnapshot]) -> WindowRestoreResult {
        calls.append(snapshots)

        if snapshots.isEmpty {
            let result = WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 0,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0,
                resolvedSnapshots: []
            )
            results.append(result)
            return result
        }

        // Sometimes converge immediately to exercise completion paths.
        if rng.nextInt(100) < 25 {
            let result = WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 1,
                alreadyAlignedCount: 0,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0,
                resolvedSnapshots: snapshots
            )
            results.append(result)
            return result
        }

        let resolvedCount = rng.nextInt(snapshots.count + 1)
        let resolved = Array(snapshots.prefix(resolvedCount))
        let remainingCount = snapshots.count - resolvedCount

        if remainingCount == 0 {
            let result = WindowRestoreResult(
                isComplete: true,
                movedWindowCount: 0,
                alreadyAlignedCount: snapshots.count,
                recoverableFailureCount: 0,
                deferredSnapshotCount: 0,
                resolvedSnapshots: resolved
            )
            results.append(result)
            return result
        }

        let deferredCount = rng.nextInt(remainingCount + 1)
        let result = WindowRestoreResult(
            isComplete: false,
            movedWindowCount: rng.nextInt(3),
            alreadyAlignedCount: rng.nextInt(3),
            recoverableFailureCount: remainingCount,
            deferredSnapshotCount: deferredCount,
            resolvedSnapshots: resolved
        )
        results.append(result)
        return result
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        // SplitMix64 for stable pseudo-random traces.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(nextUInt64() % UInt64(upperBound))
    }
}

private final class ManualScheduler: SleepWakeScheduling {
    private final class Token: CancellableTask {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private struct Pending {
        let token: Token
        let action: () -> Void
    }

    private var pending: [Pending] = []

    var pendingCount: Int {
        pending.count
    }

    var livePendingCount: Int {
        pending.reduce(into: 0) { count, item in
            if !item.token.isCancelled {
                count += 1
            }
        }
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> CancellableTask {
        let token = Token()
        pending.append(Pending(token: token, action: action))
        return token
    }

    func runAll() {
        let toRun = pending
        pending.removeAll()

        for item in toRun where !item.token.isCancelled {
            item.action()
        }
    }

    func runNext() {
        guard !pending.isEmpty else {
            return
        }

        let next = pending.removeFirst()
        if !next.token.isCancelled {
            next.action()
        }
    }
}
