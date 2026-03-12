# Stay Design

## Purpose

Stay is a lightweight macOS utility that restores app windows to their pre-sleep displays after wake.
When macOS `Displays have separate Spaces` is enabled, Stay intentionally stands down and
leaves window placement entirely under macOS control.

The design prioritizes:

- Reliability across repeated/out-of-order sleep and wake events
- Low overhead (menu bar utility, no heavy background processing)
- Minimal dependencies (Swift + Apple frameworks)
- Predictable behavior when displays wake later than the OS

## High-Level Architecture

The app is split into two layers:

1. `StayCore` (pure logic, testable)
- Sleep/wake state machine (`SleepWakeCoordinator`)
- Protocols for capture/restore/scheduling/readiness/persistence
- Pure snapshot-set transforms (`SnapshotSetOperations`) for app-level merge and resolved-snapshot pruning
- JSON snapshot persistence
- Models for saved window state

2. `Stay` (macOS integration)
- App lifecycle and menu bar UI (`StayApplicationDelegate`)
- launch-time separate-spaces policy gate and user notification
- macOS sleep/wake notification observer
- awake-time screen-configuration observer for stale snapshot invalidation
- Accessibility-based window capture/restore service
- Display mapping and display readiness checks

This separation keeps OS-specific behavior out of core logic and allows deterministic unit tests.

## Runtime Flow

### 1. Launch

- `main.swift` starts an accessory app (menu bar utility, no dock window).
- `StayApplicationDelegate` first reads `com.apple.spaces` `spans-displays`.
- If `Displays have separate Spaces` is enabled, Stay:
  - does not start sleep/wake capture or restore services
  - disables manual capture/restore menu actions
  - sends a best-effort notification explaining that macOS is already preserving placement
- Otherwise `StayApplicationDelegate` wires services:
  - `AXWindowSnapshotService` for capture/restore
  - `JSONSnapshotRepository` for persistence
  - `DisplayWakeReadinessChecker` for display wake gating
  - `SleepWakeCoordinator` for orchestration
  - `SleepWakeObserver` for `willSleep`/`didWake` notifications

Why: when each display has its own space, macOS already preserves placement well enough
that Stay's intervention is more likely to interfere than help.
The setting also requires a full logout/login cycle before the live Space topology updates,
so Stay does not need to monitor it dynamically after launch; the app will be relaunched
under the newly applied setting.

### 2. On `willSleep`

- Coordinator captures current window snapshots.
- Captured snapshots are merged with persisted snapshots using per-app freshness:
  keep the latest per-app set when that app was captured at `willSleep`, and only
  use persisted snapshots for apps missing entirely from latest capture.
- Capture can also mark apps explicitly observed with zero windows; when that
  happens, persisted fallback windows for those apps are suppressed so stale
  windows are not resurrected on wake.
- AX capture skips full-screen windows and suppresses matching WindowServer
  fallback surfaces so macOS full-screen spaces stay under system control
  instead of being treated as restorable normal windows.
- In-memory wake cache is overwritten on every sleep cycle (including empty
  merges) so stale snapshots from earlier cycles cannot leak into a later wake.
- Any pending restore task is canceled.
- Captured snapshots are cached in memory and persisted to disk.

Why: capture as late as possible before sleep and keep a durable fallback.

### 3. On `didWake`

- Coordinator validates this wake belongs to a prior sleep cycle.
- It schedules a delayed restore attempt.
- Each attempt runs readiness checks; if not ready, it retries after a short interval.
- Once ready (or timed out), restore is attempted and returns structured progress
  (`moved`, `already aligned`, `recoverable failures`, `deferred snapshots`).
- Restore attempts now also return which snapshots were actually resolved; coordinator
  removes those from the pending set so later retries only target unresolved windows.
- Restore attempts now also report snapshots deferred specifically due to inactive
  workspace visibility; coordinator moves those into an inactive-workspace pending subset.
- Retries continue until either:
  - restore succeeds, or
  - retries stagnate (no progress), then the app waits for environment change, or
  - timeout is reached, then the app waits for a concrete environment-change signal to retry.
- Deferred windows are treated in two phases:
  - before any placement progress, Stay keeps interval retries active to allow late AX exposure
  - after placement progress has occurred, repeated deferred no-progress attempts are treated as
    stagnation to avoid visible restore loops
- If stagnation is reached and all remaining failures are deferred-only windows, Stay enters a
  deferred-space wait mode (no interval retries) and waits for environment changes
  (for example, active-space switch) before retrying.
- In deferred-space wait mode, retries are gated to active-space change notifications
  only when inactive-workspace pending snapshots exist; otherwise any environment
  change may trigger retry.
- Repeated unchanged residual restore state (`recoverable failures`, `deferred count`,
  `already aligned`) is treated as stagnation even if `moved > 0`, preventing false-progress
  loops where one window keeps reporting as moved without reducing unresolved failures.
- Working assumption for workspace behavior: windows do not migrate between workspaces
  across sleep/wake; Stay tracks active-vs-inactive visibility during restore rather
  than attempting cross-workspace identity migration.

Why: OS wake is often earlier than external monitor wake.

### 4. On user-triggered restore

- The menu-bar `Restore Layout Now` action starts the same restore-cycle state machine
  used after wake, but with an immediate first attempt instead of a wake delay.
- This means workspace-specific deferrals survive the first restore invocation and stay
  pending until a later `activeSpaceDidChange` exposes the window again.
- Manual restore therefore does not force a workspace switch; it waits for the user or
  macOS to make the target workspace active and retries then.

Why: direct restore should behave like wake restore for deferred windows instead of
discarding pending workspace state after a single AX pass.

### 5. While separate spaces is enabled

- Stay does not create a `SleepWakeCoordinator` or `SleepWakeObserver`, so it does not
  capture on sleep or restore on wake.
- Manual menu actions remain visible for discoverability but are disabled.
- Notification delivery is best-effort: if the user has denied notification permission,
  the menu-bar status line still explains that Stay is paused.
- Stay does not watch for runtime changes to `spans-displays`; macOS applies that toggle
  on the next logout/login cycle, so a fresh Stay launch picks up the correct mode.

Why: the safest behavior for this macOS mode is to stay out of the way while still
making the paused state explicit.

### 6. On awake-time screen configuration change

- `ScreenConfigurationObserver` listens for `NSApplication.didChangeScreenParametersNotification`
  while Stay is running normally.
- When the display set changes, Stay queries the currently active display IDs and
  invalidates persisted snapshots that still target displays no longer present.
- This trims stale fallback data before later manual restore or `willSleep` merge paths
  can reuse windows from a display that has already been removed.
- The current roadmap scope intentionally stops at invalidation: if the same display later
  reconnects, or a display disappears only during sleep/wake, those behaviors are handled by
  later roadmap items.

Why: while the app is awake, a missing display is an actual topology change, not a wake-timing
ambiguity, so the safest baseline is to discard stale targets immediately.

## Display Readiness Logic

`DisplayWakeReadinessChecker` enforces strict conditions:

- Every snapshot must have a known `screenDisplayID`.
- Every required display ID must be online (`CGGetOnlineDisplayList`).
- Every required display ID must be awake (`CGDisplayIsAsleep == 0`).

If any condition fails, readiness is `false` and coordinator keeps retrying.

If readiness never succeeds before timeout, coordinator still attempts restore, but does not spin forever.
It waits for environment-change notifications (screens/session/space change) to retry.
Post-timeout retries are capped so repeated environment-change notifications cannot cause
an endless restore loop.
If deferred snapshots remain, timeout capping is bypassed and Stay keeps pending work for
later active-space changes.

The same readiness and environment-change logic is shared by wake-triggered restores and
manual restores; on a normal awake desktop, manual restores usually pass readiness immediately.

Why: avoids premature restore while monitors are still unavailable, but prevents infinite waits.

## Capture and Restore Logic

### Capture

- Enumerates regular running apps.
- Reads AX windows (`kAXWindowsAttribute`) and, when needed, discovers additional
  window-like AX elements from focused/child trees (for apps with non-standard tool windows).
- If AX yields no windows for an app:
  - first falls back to WindowServer on-screen windows
  - if still empty, falls back to the full WindowServer list and applies filtering
    (dedupe, menu-bar strip rejection, and preference for non-zero layer windows)
    so apps like FreeCAD still get snapshots when inactive.
- If AX yields only a partial set, Stay merges in unique WindowServer windows so tool
  windows are not dropped from the saved layout.
- Partial merge is intentionally conservative: if AX already captured windows, extra
  fallback windows are merged only when fallback contains non-zero-layer windows
  (to avoid polluting snapshots with layer-0 duplicates/chrome from regular apps).
- Finder Desktop pseudo-windows are filtered at capture time so non-restorable
  desktop entries do not pollute multi-window matching/assignment.
- Finder capture augments `kAXWindowsAttribute` with discovered window-like AX
  children to recover Finder windows that are not always surfaced in the top-level list.
- Finder non-window AX pseudo-surfaces (for example `AXScrollArea` desktop-like
  entries) are filtered at capture time.
- Finder WindowServer fallback windows are merged when AX captures no Finder
  windows, or when AX capture includes non-window pseudo-surfaces that indicate
  an incomplete Finder window set.
- For non-Finder apps, partial fallback merge is restricted to non-zero-layer
  WindowServer entries when AX already returned windows. This avoids polluting
  snapshot sets with extra layer-0 surfaces.
- For non-Finder apps where AX captures zero windows and only `all-window-list`
  has candidates, Stay requires non-zero-layer evidence before accepting fallback
  entries. If that evidence is absent, capture treats the app as having no open windows.
- Reads each window's frame (`kAXPositionAttribute`, `kAXSizeAttribute`).
- Associates each window with a display ID via screen intersection/nearest-screen fallback.
- Saves app/window identity fields (PID, title, index) and frame.
- Enriches identity metadata with optional `windowNumber`, role, and subrole to
  stabilize matching for untitled tool-window-heavy apps.

### Restore

- Groups snapshots by PID.
- Resolves target apps by PID first, then bundle ID / app name remapping when PID is stale.
- Reads current AX windows for each app.
- Uses WindowServer on-screen window numbers to partition app snapshots into:
  - eligible now (current active space)
  - deferred (inactive space / not currently visible)
- Includes deferred inactive-space snapshots in `WindowRestoreResult` so coordinator
  can park interval retries and wait for `activeSpaceDidChange`.
- Multi-window app activation is intentionally limited; automatic wake restore does not
  force-activate multi-window apps just to expose hidden space windows.
- Performs app-level one-to-one assignment across all snapshot/live-window pairs using
  scored identity strength (`windowNumber` > role/subrole > title > frame > index).
- Matching is confidence-gated: low-confidence index-only matching is limited to
  single-window restore sets, and multi-window sets require stronger identity.
- Unmatched snapshots are counted as recoverable failures; no app-specific pre-drop is
  treated as resolved before matching.
- Finder-specific restore handling:
  - Finder is explicitly activated before restore attempts, and Finder windows are raised before frame writes
  - only AX windows with settable frame attributes are considered restore candidates
  - Finder restore is display-first: if a Finder window is already on the target display, it is treated as aligned even if size differs
  - Finder move writes use position-first restore (not strict size replay), and always run a second-step `AXFrame` fallback when initial convergence fails
  - Finder convergence checks use target-display membership (with origin fallback), not strict frame equality, to tolerate Finder’s per-display size memory
- Before writing AX position/size, restore compares current and target frame and skips
  writes for windows that are already aligned within tolerance.
- Restore also performs a display-alignment short-circuit: when all matched
  windows for an app are already on their expected displays, frame writes are
  skipped to avoid unnecessary visible movement/resizing.
- Restores frame using screen-aware adjustment:
  - prefer original display ID when available
  - clamp to visible area to avoid off-screen placement
- AX setFrame "success" is verified by reading back the frame shortly after the write;
  if the frame does not converge, the move is treated as recoverable failure so
  coordinator retries instead of incorrectly declaring success.
- Returns a structured restore outcome. Completion requires zero recoverable failures.
  Recoverable failures include transient AX conditions (for example, attribute unsupported
  immediately after wake) and running apps that temporarily expose zero AX windows.
  Deferred snapshot counts identify apps that have not exposed all expected windows yet;
  coordinator keeps interval retries active in this case instead of parking too early.

Why: robust matching while keeping implementation simple and lightweight.

## Persistence Strategy

- Snapshots are written to:
  - `~/Library/Application Support/Stay/window-layout.json`
- Awake-time screen-configuration changes may prune persisted snapshots whose saved
  `screenDisplayID` no longer exists in the live display set.
- Write failures are non-fatal.
- In-memory snapshots are still used within the current cycle.

Why: best-effort persistence without blocking runtime behavior.

## Event Resilience

Coordinator handles edge cases explicitly:

- Duplicate wake events do not trigger duplicate restores.
- New sleep events cancel pending restore attempts.
- Wake-before-sleep is ignored.
- Failed capture can fall back to previously persisted snapshots.
- Failed restore attempts are retried while the wake cycle is active.
- Screens waking, session becoming active, or workspace changes can retrigger restore attempts.
- Deferred-only residual windows remain pending so later space changes can complete restore.

## Testing Strategy

Automated tests focus on deterministic logic in `StayCore`:

- Repeated/out-of-order event handling
- Pending restore cancellation on new sleep cycle
- Retry-until-ready behavior
- Timeout fallback behavior
- Restore-failure retry behavior
- Environment-change retrigger behavior after timeout
- Stale-cache prevention across consecutive sleep cycles

Real-app no-sleep integration tests in `StayIntegrationTests.RealAppScenarioTests` cover:

- two Finder windows across two displays
- two TextEdit windows across two displays
- one TextEdit window captured on a secondary Mission Control workspace, then restored
  when that workspace becomes active again
- one full-screen TextEdit window ignored while Finder windows are captured/restored
- FreeCAD main window + child windows (tasks/model/report/python console) across two displays
- KiCad main + PCB editor on primary display, schematic editor on secondary display

Wake-cycle integration uses the `WakeCycleScenarios` executable:

- `prepare finder|app|app-workspace|freecad|kicad`: create/position real windows, persist state,
  optionally sleep the machine. Scripted scenarios (`finder`, `app`, `app-workspace`) quit any
  already-running target app first so stale windows cannot leak into a new run.
- `verify finder|app|app-workspace|freecad|kicad`: wait for display readiness, then wait for
  app/window readiness (tracked windows must be discoverable and matchable), perturb one
  tracked window, run restore attempts, then verify final display+frame alignment
- `verify ... --check-only`: passive post-wake validation without perturb/restore
- `cycle finder|app|app-workspace|freecad|kicad`: full-cycle mode for sleep/wake automation

`cycle` execution model:

- The runner process stays alive; on sleep it is suspended by macOS and resumes with the
  same PID after wake.
- Before sleeping, `cycle` persists a cycle-state file.
- After wake/login, the runner waits for wake/session signals (`didWake`,
  `screensDidWake`, `sessionDidBecomeActive`) and then runs `verify` automatically
  using extended readiness timeouts.
- A LaunchAgent fallback is available as an opt-in path (`STAY_CYCLE_ENABLE_LAUNCH_AGENT=1`),
  but is disabled by default.
- Successful completion writes the standard scenario report and removes temporary cycle-state data.

`WakeCycleScenarios` is intentionally split into focused support modules:

- orchestration and command routing in `main.swift`
- scenario path/report/launch-agent naming helpers in `ScenarioPathSupport.swift`
- wake-cycle `cycle`/`resume` command orchestration in `CycleCommandSupport.swift`
- generic runner utilities in `RunnerSupport.swift`
- app/PID/window discovery helpers in `AppWindowDiscoverySupport.swift`
- scenario precondition/display/script setup helpers in `ScenarioSetupSupport.swift`
- prepare/verify command orchestration in `ScenarioCommandSupport.swift`
- AX/window frame + display helpers in `WindowAXSupport.swift`
- display/app readiness waiting helpers in `ReadinessSupport.swift`
- verification/readiness/restore-convergence helpers in `VerificationSupport.swift`
- FreeCAD-specific window-selection heuristics in `FreeCADWindowSelectionSupport.swift`
- wake-cycle signal/launch-agent/state-control helpers in `WakeCycleControlSupport.swift`
- shared non-AppKit parser/state-codec logic in `WakeCycleScenariosCore`
  (`InvocationParsing.swift`, `CycleStateCodec.swift`, `ScenarioPersistence.swift`, `ScenarioMetadata.swift`)

`WakeCycleScenariosCore` isolates deterministic command/state code from AppKit runtime
code so parser/state behavior can be unit tested without launching apps or windows.

Physical sleep/display wake timing is intentionally left for manual/QA validation on real hardware.

## Observability

Runtime logging is emitted via `OSLog` for:

- sleep/wake and environment-change notifications
- readiness checker decisions (required displays, online displays, asleep state)
- coordinator retry state (ready/timed-out/restore-success)
- AX restore outcomes including `AXUIElementSetAttributeValue` error codes

These logs are intended to diagnose timing issues specific to real wake/login cycles.

## Known Limits / Future Work

- AX permissions are required; without them Stay cannot manage windows.
- Some apps may restrict AX window moves.
- Future improvements:
  - explicit wake/login sequencing state machine for complex monitor timing:
    - displays waking in different orders
    - login occurring while only a subset of displays is active
    - keep this logic in `StayCore` state transitions (avoid ad-hoc procedural handling)
  - richer logging/diagnostics for readiness state
  - optional user-configurable retry/timeout policy
  - launch-at-login and distribution packaging flow
