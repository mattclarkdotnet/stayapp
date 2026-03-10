# Automated Tests Guide

## Role of Automated Tests

Automated tests cover two layers:

- deterministic coordinator/logic behavior in `StayCore`
- user-facing no-sleep scenarios in `Tests/SCENARIOS.md` using real macOS apps and real windows

## Where Tests Live

- Core tests: `Tests/StayCoreTests/SleepWakeCoordinatorTests.swift`
- Fixture round-trip tests: `Tests/StayIntegrationTests/WindowRoundTripTests.swift`
- Real-app scenario tests: `Tests/StayIntegrationTests/RealAppScenarioTests.swift`

## How to Run

```bash
swift test
```

To run only the real-app scenarios:

```bash
swift test --filter StayIntegrationTests.RealAppScenarioTests
```

Wake-cycle scenarios (with real sleep/wake) use the runner executable:

```bash
# Finder scenario
swift run WakeCycleScenarios prepare finder
# ...machine sleeps, wakes, and you log in...
swift run WakeCycleScenarios verify finder

# TextEdit scenario
swift run WakeCycleScenarios prepare app
# ...machine sleeps, wakes, and you log in...
swift run WakeCycleScenarios verify app
```

Required order for wake-cycle scenarios:

1. Run `prepare` for the scenario (`finder` or `app`).
2. Let the machine complete the sleep/wake cycle.
3. Log in after wake.
4. Run `verify` for the same scenario.

Optional passive check:

```bash
swift run WakeCycleScenarios verify finder --check-only
swift run WakeCycleScenarios verify app --check-only
```

## Real-App Scenario Prerequisites

- Exactly two external displays must be active (no built-in display).
- Accessibility permission for Stay/test process must be granted.
- Finder, TextEdit, and FreeCAD must be launchable.
- FreeCAD child windows used in Scenario 1.3 must be visible as independent AX windows.
- Running these tests will visibly move windows across screens.
- For wake-cycle scenarios, run `prepare`, let the machine sleep/wake, log in, then run `verify`.
- `verify` perturbs one tracked window first, then restores and validates display and frame placement.
- Use `verify --check-only` when you only want passive post-wake validation.

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

## Scenario Automation Blueprint

For each real-app scenario:

1. Launch target app and create/prepare the real windows required by the scenario.
2. Run capture and store the snapshots as the expected baseline.
3. Move/resize windows to known incorrect frames.
4. Run restore.
5. Assert:
- windows returned to captured frames (within tolerance)
- windows returned to expected display IDs
- restore metrics match expected behavior (`moved`, `aligned`, `failures`, `deferred`)

Scenarios currently automated from `SCENARIOS.md`:

- two Finder windows, one per screen
- two non-Finder app windows (TextEdit), one per screen
- FreeCAD main window + child windows (tasks/model/report/python console) across two screens
- full wake/sleep Finder two-window scenario (`WakeCycleScenarios prepare/verify finder`)
- full wake/sleep app two-window scenario (`WakeCycleScenarios prepare/verify app`)

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
- Finder-specific capture/restore quirks (Desktop pseudo-window filtering, display-first restore semantics)

## When a Bug Is Found

1. Reproduce with logs.
2. Add a failing automated test for the affected layer:
- `StayCoreTests` for state-machine logic
- `RealAppScenarioTests` or `WindowRoundTripTests` for capture/restore behavior
3. Implement fix.
4. Ensure test passes and existing suite remains green.

If a bug depends on OS/hardware behavior that cannot be unit-tested directly,
add the nearest deterministic test around coordinator decisions and keep the
hardware scenario documented in QA notes.
