# Automated Tests Guide

## Role of Automated Tests

Automated tests validate deterministic logic in `StayCore` and protect against
regressions in event handling and retry behavior.

Current focus:

- sleep/wake coordinator state transitions
- retry and timeout semantics
- behavior under repeated/out-of-order notifications
- fallback/merge behavior for partial capture sets

## Where Tests Live

- Core tests: `Tests/StayCoreTests/SleepWakeCoordinatorTests.swift`

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

## Adding New Test Cases

When adding a case:

1. Express the scenario as a sequence of coordinator events.
2. Control restore/readiness outcomes with test doubles.
3. Assert both state effects and side effects:
- scheduled retry count
- restore invocation count
- snapshot payload used for restore

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

## When a Bug Is Found

1. Reproduce with logs.
2. Add a failing unit test that models the core logic gap.
3. Implement fix.
4. Ensure test passes and existing suite remains green.

If a bug depends on OS/hardware behavior that cannot be unit-tested directly,
add the nearest deterministic test around coordinator decisions and keep the
hardware scenario documented in QA notes.
