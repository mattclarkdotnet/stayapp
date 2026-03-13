# Automated Tests Guide

## Role of Automated Tests

Automated tests cover two layers:

- deterministic coordinator/logic behavior in `StayCore`
- user-facing no-sleep scenarios in `Tests/SCENARIOS.md` using real macOS apps and real windows

## Where Tests Live

- Core tests: `Tests/StayCoreTests/SleepWakeCoordinatorTests.swift`
- Core helper tests: `Tests/StayCoreTests/SnapshotSetOperationsTests.swift`
- Stay process identity tests: `Tests/StayCoreTests/StayProcessIdentityTests.swift`
- Persistence invalidation tests: `Tests/StayCoreTests/JSONSnapshotRepositoryTests.swift`
- Wake-cycle core tests: `Tests/WakeCycleScenariosCoreTests/*`
- Wake-cycle core coverage includes invocation parsing, scenario metadata, cycle-state codecs, scenario-state/report codecs, and malformed decode paths
- Bundle metadata tests: `Tests/StayIntegrationTests/BundleMetadataTests.swift`
- Direct-distribution script tests: `Tests/StayIntegrationTests/DirectDistributionScriptTests.swift`
- Default launch-at-login tests: `Tests/StayIntegrationTests/DefaultLaunchAtLoginEnablerTests.swift`
- Launch-at-login tests: `Tests/StayIntegrationTests/LaunchAtLoginControllerTests.swift`
- Advanced menu tests: `Tests/StayIntegrationTests/AdvancedMenuPresentationTests.swift`
- Menu presentation tests: `Tests/StayIntegrationTests/StayMenuPresentationTests.swift`
- Fixture round-trip tests: `Tests/StayIntegrationTests/WindowRoundTripTests.swift`
- Restore availability tests: `Tests/StayIntegrationTests/AXWindowSnapshotServiceTests.swift`
- Separate-spaces policy tests: `Tests/StayIntegrationTests/SeparateSpacesPolicyTests.swift`
- Screen-configuration observer tests: `Tests/StayIntegrationTests/ScreenConfigurationObserverTests.swift`
- Real-app scenario tests: `Tests/StayIntegrationTests/RealAppScenarioTests.swift`

## How to Run

```bash
swift test
```

To run deterministic wake-cycle parser/state tests only:

```bash
swift test --filter WakeCycleScenariosCoreTests
```

To run the Stay process identity coverage:

```bash
swift test --filter StayProcessIdentityTests
```

To run only the real-app scenarios:

```bash
swift test --filter StayIntegrationTests.RealAppScenarioTests
# disable visual confirmation delays (optional)
STAY_REALAPP_VISUAL_PAUSE=0 swift test --filter StayIntegrationTests.RealAppScenarioTests
```

To run only the separate-spaces suspension coverage:

```bash
swift test --filter SeparateSpacesPolicyTests
```

To run the awake-time display invalidation coverage:

```bash
swift test --filter 'JSONSnapshotRepositoryTests|ScreenConfigurationObserverTests'
```

To run the missing-display restore safety coverage:

```bash
swift test --filter AXWindowSnapshotServiceTests
```

To run the bundle metadata coverage:

```bash
swift test --filter BundleMetadataTests
```

To run the menu presentation coverage:

```bash
swift test --filter StayMenuPresentationTests
```

To run the direct-distribution script coverage:

```bash
swift test --filter DirectDistributionScriptTests
```

To run the default launch-at-login coverage:

```bash
swift test --filter DefaultLaunchAtLoginEnablerTests
```

To run the advanced-menu coverage:

```bash
swift test --filter AdvancedMenuPresentationTests
```

To run the launch-at-login coverage:

```bash
swift test --filter LaunchAtLoginControllerTests
```

To validate the notarization workflow manually:

```bash
./Scripts/store-notary-credentials.sh StayNotary
NOTARY_PROFILE=StayNotary ./Scripts/notarize-stay-app.sh
```

To run the guided real-hardware awake-time display-disconnect/reconnect check:

```bash
swift run WakeCycleScenarios awake-display finder
swift run WakeCycleScenarios awake-display app
```

Wake-cycle scenarios (with real sleep/wake) use the runner executable:

```bash
# Full-cycle automation (preferred):
swift run WakeCycleScenarios cycle finder
swift run WakeCycleScenarios cycle app
swift run WakeCycleScenarios cycle app-workspace
swift run WakeCycleScenarios cycle freecad
swift run WakeCycleScenarios cycle kicad

# Manual split flow (debugging):
swift run WakeCycleScenarios prepare finder
swift run WakeCycleScenarios verify finder
swift run WakeCycleScenarios prepare app-workspace
swift run WakeCycleScenarios verify app-workspace
```

Required order for manual split wake-cycle scenarios:

1. Run `prepare` for the scenario (`finder`, `app`, `app-workspace`, `freecad`, or `kicad`).
2. Let the machine complete the sleep/wake cycle.
3. Log in after wake.
4. Run `verify` for the same scenario.

Required order for full-cycle automation:

1. Run `cycle` for the scenario (`finder`, `app`, `app-workspace`, `freecad`, or `kicad`).
2. Let the machine sleep.
3. Wake/unlock the machine.
4. Runner automatically continues with verify and writes the report.

Optional passive check:

```bash
swift run WakeCycleScenarios verify finder --check-only
swift run WakeCycleScenarios verify app --check-only
swift run WakeCycleScenarios verify app-workspace --check-only
swift run WakeCycleScenarios verify freecad --check-only
swift run WakeCycleScenarios verify kicad --check-only
```

Guided awake-time display-disconnect/reconnect QA:

1. Run `swift run WakeCycleScenarios awake-display finder` or `swift run WakeCycleScenarios awake-display app`.
2. Disconnect the secondary display when prompted.
3. Reconnect the same secondary display when prompted.
4. The runner handles window setup, snapshot creation, invalidation verification, reconnect verification, and cleanup.
5. The runner terminates any already-running `Stay` instance before it starts and again when it finishes.

## Full-Cycle Automation Behavior

- `cycle` keeps the runner alive across sleep/wake by remaining in-process; macOS suspends and resumes it.
- After wake/login, `cycle` waits for wake/session signals and then runs `verify` automatically.
- `verify` still enforces display readiness and app/window readiness before perturb/restore.
- LaunchAgent fallback support exists but is opt-in (`STAY_CYCLE_ENABLE_LAUNCH_AGENT=1`).
- The only required user action is waking/unlocking the machine.

## Real-App Scenario Prerequisites

- Exactly two external displays must be active (no built-in display).
- In scenario tests, `screen 1` means the primary macOS display (menu bar display).
- Accessibility permission for Stay/test process must be granted.
- `Displays have separate Spaces` must be OFF for real-app capture/restore scenarios;
  if it is ON, Stay intentionally pauses itself instead of moving windows.
- Finder, TextEdit, FreeCAD, and KiCad must be launchable.
- FreeCAD child windows used in Scenario 1.3 must be visible as independent AX windows.
- FreeCAD Scenario 1.3 includes one app relaunch retry if the expected child windows are not exposed on first activation.
- KiCad Scenario 1.4 requires visible windows for the KiCad app, PCB editor, and schematic editor.
- Scenario 1.3 explicitly repositions FreeCAD windows before capture:
  main window on screen 1, child windows (`tasks`, `model`, `report view`, `python console`) on screen 2.
- Scenario 1.3 uses position-only moves for FreeCAD windows so tool-window sizes are preserved.
- Running these tests will visibly move windows across screens.
- Visual confirmation delays are enabled by default; set `STAY_REALAPP_VISUAL_PAUSE=0` to disable them.
- Scripted Finder/TextEdit real-app scenarios reset their target app before setup.
- TextEdit, FreeCAD, and KiCad real-app scenarios explicitly quit those apps during cleanup.
- For wake-cycle scenarios, prefer `cycle`; use `prepare`/`verify` split flow for debugging.
- `verify` waits for display and app/window readiness first, then perturbs one tracked window, restores, and validates display and frame placement.
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
- launch-time pause mode when `Displays have separate Spaces` is enabled
- awake-time display disconnect invalidating stale saved snapshots for that display
- awake-time display disconnect invalidating stale queued restore targets before they run
- awake-time same-display reconnect restoring windows back to the reconnected display
- post-wake missing-display snapshots staying deferred instead of being remapped to an available screen
- checked-in app-bundle metadata remaining aligned with the intended `Stay.app` identity
- checked-in direct-distribution scripts remaining aligned with the intended notarized-download release path
- first installed launch defaulting login-item registration on without re-enabling after later user opt-out
- advanced menu structure keeping manual actions grouped and exposing the latest persisted snapshot contents
- menu-bar status presentation showing explicit ready/paused state with the installed icon metadata
- one TextEdit window on a secondary workspace, restored when that workspace becomes active
- one full-screen TextEdit window ignored while Finder windows are restored normally
- FreeCAD main window + child windows (tasks/model/report/python console) across two screens
- KiCad main + PCB editor on primary screen, schematic editor on secondary screen
- full wake/sleep Finder two-window scenario (`WakeCycleScenarios prepare/verify finder`)
- full wake/sleep app two-window scenario (`WakeCycleScenarios prepare/verify app`)
- full wake/sleep secondary-workspace TextEdit scenario (`WakeCycleScenarios prepare/verify app-workspace`)
- full wake/sleep FreeCAD main+child-window scenario (`WakeCycleScenarios prepare/verify freecad`)
- full wake/sleep KiCad main+PCB+schematic scenario (`WakeCycleScenarios prepare/verify kicad`)

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
- explicitly empty apps suppressing stale persisted fallback snapshots
- repeated restore on an already-aligned layout remains a no-op
- readiness flapping (display online/offline transitions)
- restore failing transiently before succeeding
- timeout reached before readiness
- environment-change retrigger after timeout
- stale snapshot identity (PID drift, bundle/name fallback behavior)
- deferred-only residuals parking until active-space/environment change
- manual restore requests retaining deferred inactive-workspace snapshots until a later
  `activeSpaceDidChange`
- inactive-workspace-specific deferrals (`deferredInactiveWorkspaceSnapshots`) only
  retrying after `activeSpaceDidChange`
- full-screen windows being excluded from capture/fallback so restore does not target them
- separate-spaces launch gating pausing Stay and disabling manual capture/restore
- awake-time screen-parameter changes invalidating stale persisted display targets
- awake-time screen-parameter changes invalidating stale in-memory pending restore targets
- awake-time same-display reconnect reactivating suspended targets and restoring windows automatically
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
