# Testing Strategy

## Principles

- Any failing tests must be captured as new test cases, whether they come from compilation, user feedback, or unexpected behavior.
- Tests must be kept in sync with functional code.
- Do not keep tests that are no longer relevant
- Focus on common paths first
- Add explicit tests for edge cases that are universal across all kinds of apps:
  - Repeated events
  - Unparseable inputs
  - Unexpected delays
  - App termination
  - Data values not expected
- Consider property testing for core code logic

## Purpose

Stay handles OS sleep/wake timing, multi-display behavior, and Accessibility APIs.
The testing approach is layered so we can get fast confidence from automation while
still validating real hardware behavior with human-in-loop QA.

## Separation Goal

To isolate root causes, treat testing as two distinct domains:

- Window layout capture/restore logic (deterministic where possible)
- Sleep/wake orchestration and hardware timing (non-deterministic)

The automated plan below prioritizes the first domain so layout correctness can be
proven without a real sleep cycle.

## Automated Plan: Capture and Restore

### Scope to automate

- capture decisions (AX + WindowServer fallback merge behavior)
- snapshot merge behavior (latest vs persisted)
- restore matching behavior (window identity and frame matching)
- frame application decisions (already-aligned vs move vs defer)
- convergence decisions (retry, wait, or conclude)

### Proposed test layers for this scope

1. Pure logic tests (highest priority)
- Extract or keep logic in testable functions/services that do not call AppKit directly.
- Validate matching, merge, and convergence rules with fixtures and table-driven tests.

2. Service-level tests with fakes
- Test `AXWindowSnapshotService` behavior using fake AX/window-server/screen adapters.
- Verify fallback merge, deferred-window handling, and move/aligned/failure accounting.

3. Coordinator contract tests (already present, continue expanding)
- Keep `SleepWakeCoordinator` tests focused on when restore is invoked and how retry state changes.
- Do not use these tests to validate matching correctness inside restore.

### Automated round-trip layout tests (no sleep)

Add a dedicated automated path that performs the full layout round-trip:

1. launch a fixture app that can open deterministic test windows
2. create one or more windows with known titles/frames across displays
3. call capture and persist snapshots
4. deliberately perturb windows (move/resize/swap displays)
5. call restore
6. assert final frames match captured frames within tolerance

Purpose:

- prove capture/restore correctness independent of true sleep/wake timing
- detect regressions in matching, fallback merge, and frame application

Minimum scenario set:

- single-window app round-trip
- multi-window titled app round-trip
- untitled/tool-window round-trip (FreeCAD-like)
- mixed app set where one app is partially unavailable during restore
- stale persisted snapshot does not override fresh capture for same app

Required assertions per scenario:

- captured snapshot count is expected
- perturbation actually changed layout before restore
- restore result metrics are expected (`moved`, `aligned`, `failures`, `deferred`)
- post-restore window frames are in expected display and coordinates

### Test seam plan

To keep automation deterministic, model OS dependencies behind protocols/fakes:

- AX window provider (list windows, read frame/title, set frame)
- WindowServer provider (on-screen/all-window lists)
- Running app provider / PID resolution
- Screen mapping and frame adjustment service

This allows replaying hard cases (Finder, FreeCAD, untitled tool windows) without
real monitors or wake transitions.

For round-trip tests, use a controllable fixture-app API so windows can be created
and moved by the test harness instead of relying on real user apps.

### Fixture matrix for layout logic

Add reusable fixture sets for:

- Finder with Desktop + regular windows (partial AX exposure)
- FreeCAD with multiple untitled tool windows across displays
- mixed titled/untitled windows
- stale persisted snapshots vs fresh capture
- PID drift with stable bundle IDs
- display topology changes (missing display, remapped display IDs)

Each fixture should include expected capture output and expected restore result
(`moved`, `aligned`, `recoverable failures`, `deferred`).

### Acceptance checks for automated capture/restore tests

- No stale persisted window may block restoring fresh captured windows for the same app.
- Available windows must still restore when some app windows are deferred.
- Re-running restore on an already-restored layout must be a no-op (no extra moves).
- Deferred-only residuals must park without interval loops and retry on environment change.
- Matching must remain stable when titles are missing (untitled windows).

### Delivery order

1. Expand `StayCore` tests for merge/convergence edge cases (fastest coverage gain).
2. Introduce focused service-level tests for `AXWindowSnapshotService` with fakes.
3. Keep real sleep/wake QA as a final validation layer, not the first debugging tool.


## Test Layers

### 1. Unit Tests (fast, deterministic)

Scope:

- `StayCore` state machine and retry logic (`SleepWakeCoordinator`)
- pure snapshot-set transforms (`SnapshotSetOperations`) for per-app merge and resolved-snapshot pruning
- `WakeCycleScenariosCore` deterministic parsing/serialization helpers
  (`WakeCycleInvocationParser`, `WakeCycleStateCodec`, `ScenarioStateCodec`, `ScenarioReportCodec`)
- event ordering and idempotency (duplicate wake, wake-before-sleep, repeated sleep)
- persistence fallback behavior
- readiness and restore retry interactions
- seeded event-trace fuzzing with replayable seeds for coordinator invariants

Why:

- deterministic and cheap to run on every change
- no dependence on actual sleep cycles or monitor hardware

Gate:

- must pass for every change set (`swift test`)
- for parser/state refactors, run `swift test --filter WakeCycleScenariosCoreTests`
- seeded fuzz traces live in `StayCoreTests` and should stay deterministic/replayable

### 2. Integration Tests (scripted/system-level, still mostly automated)

Scope:

- real-app capture/restore scenarios without sleep (from `Tests/SCENARIOS.md`)
- end-to-end app process startup
- logging and diagnostics behavior
- sanity checks around snapshot persistence path and format

How:

- run `swift test --filter StayIntegrationTests.RealAppScenarioTests`
- tests launch real apps (Finder/TextEdit/FreeCAD/KiCad), move real windows across screens, then run capture/restore
- use logs (`log stream --predicate 'subsystem == "com.stay.app"'`) when investigating failures
- for full sleep/wake scenarios, prefer single-command cycle mode:
  1. `swift run WakeCycleScenarios cycle finder|app|freecad|kicad`
  2. let the machine sleep
  3. wake/unlock
  4. runner auto-runs verify and writes report
- manual split flow remains available for debugging:
  1. `swift run WakeCycleScenarios prepare finder|app|freecad|kicad`
  2. let the machine sleep/wake and log in
  3. `swift run WakeCycleScenarios verify finder|app|freecad|kicad`
  4. optional passive check: `swift run WakeCycleScenarios verify finder|app|freecad|kicad --check-only`

Limitations:

- requires a real two-external-display setup and Accessibility permission
- FreeCAD Scenario 1.3 also requires visible child/tool windows as independent AX windows
- true monitor wake timing and lock-screen transitions remain difficult to fully automate

### 3. Human-in-Loop QA (real hardware, real sleep cycle)

Scope:

- full sleep -> wake -> login flow
- external monitor low-power transitions
- multi-display + multi-space combinations
- app-specific behavior (Safari/Preview/Finder/etc.)

Recommended matrix:

- laptop open vs clamshell
- one external vs two or more external displays
- single space vs multiple spaces
- locked wake (login required) vs unlocked wake

Acceptance criteria:

- windows that were on secondary displays before sleep return to those displays after wake
- no persistent restore loop after success
- logs show sensible retries and eventual success or timeout behavior

## Diagnostics-Driven Testing

Use logs as first-class test evidence:

- observer events occurred in expected order
- capture count and merged snapshot count are plausible
- readiness checks match actual display state transitions
- restore failures include AX error codes and retry decisions

When failures occur, attach the `stay-wake.log` excerpt with timestamps.

## Practical Workflow

1. Run `swift test` locally.
2. Run automated capture/restore-focused tests and review fixture outputs.
3. Run app, exercise manual capture/restore sanity checks (no sleep).
4. Run one or more real sleep/wake QA scenarios.
5. Review logs for retries, readiness transitions, and final success conditions.
6. Record any hardware/app-specific regressions with logs and repro steps.
