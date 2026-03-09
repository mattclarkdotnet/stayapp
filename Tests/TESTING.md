# Automated Tests Guide

## Role of Automated Tests

Automated tests validate deterministic logic in `StayCore` and protect against
regressions in event handling and retry behavior.

Current focus:

- sleep/wake coordinator state transitions
- retry and timeout semantics
- behavior under repeated/out-of-order notifications
- fallback/merge behavior for partial capture sets
- capture/restore round-trip correctness without real sleep

## Where Tests Live

- Core tests: `Tests/StayCoreTests/SleepWakeCoordinatorTests.swift`
- Round-trip tests: `Tests/StayIntegrationTests/WindowRoundTripTests.swift`

These tests intentionally avoid real sleep cycles and real monitor state.

## How to Run

```bash
swift test
```

## Test Design Pattern

Tests use simple doubles:

- capture stub (`WindowSnapshotCapturing`)
- restore spy (`WindowSnapshotRestoring`)
- in-memory repository (`SnapshotRepository`)
- manual scheduler (`SleepWakeScheduling`)
- sequenced readiness checker (`RestoreReadinessChecking`)

This makes timing and ordering explicit without waiting on wall-clock delays.

Round-trip tests use:

- a fixture app controller (open/close/move windows deterministically)
- a capture/restore harness (invoke capture, persist, restore)
- frame assertion helpers (with tolerance and display ID checks)

## Round-Trip Automation Blueprint

For each round-trip test case:

1. Start fixture app and create windows at known frames.
2. Run capture and store the snapshots as the expected baseline.
3. Move/resize windows to known incorrect frames.
4. Run restore.
5. Assert:
- windows returned to captured frames (within tolerance)
- windows returned to expected display IDs
- restore metrics match expected behavior (`moved`, `aligned`, `failures`, `deferred`)

Core round-trip cases to implement first:

- one titled window
- multiple titled windows
- untitled/tool windows
- partial app availability during restore
- stale persisted snapshot competing with fresh capture
- windows split across displays
- apps with windows on different virtual desktops

## Adding New Test Cases

When adding a case:

1. Express the scenario as a sequence of coordinator events.
2. Control restore/readiness outcomes with test doubles.
3. Assert both state effects and side effects:
- scheduled retry count
- restore invocation count
- snapshot payload used for restore
- final window frame verification where applicable

Prefer one behavior per test, with descriptive test names.

## Edge Case Checklist

Add/expand tests for:

- duplicate `didWake` or `willSleep` notifications
- wake without prior sleep
- partial capture merged with persisted snapshots
- readiness flapping (display online/offline transitions)
- restore failing transiently before succeeding
- timeout reached before readiness
- environment-change retrigger after timeout
- stale snapshot identity (PID drift, bundle/name fallback behavior)
- deferred-only residuals parking until active-space/environment change
- untitled multi-window matching using enriched identity (`windowNumber`, role/subrole)

## When a Bug Is Found

1. Reproduce with logs.
2. Add a failing unit test that models the core logic gap.
3. Implement fix.
4. Ensure test passes and existing suite remains green.

If a bug depends on OS/hardware behavior that cannot be unit-tested directly,
add the nearest deterministic test around coordinator decisions and keep the
hardware scenario documented in QA notes.
