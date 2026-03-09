# Stay Design

## Purpose

Stay is a lightweight macOS utility that restores app windows to their pre-sleep displays after wake.

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
- JSON snapshot persistence
- Models for saved window state

2. `Stay` (macOS integration)
- App lifecycle and menu bar UI (`StayApplicationDelegate`)
- macOS sleep/wake notification observer
- Accessibility-based window capture/restore service
- Display mapping and display readiness checks

This separation keeps OS-specific behavior out of core logic and allows deterministic unit tests.

## Runtime Flow

### 1. Launch

- `main.swift` starts an accessory app (menu bar utility, no dock window).
- `StayApplicationDelegate` wires services:
  - `AXWindowSnapshotService` for capture/restore
  - `JSONSnapshotRepository` for persistence
  - `DisplayWakeReadinessChecker` for display wake gating
  - `SleepWakeCoordinator` for orchestration
  - `SleepWakeObserver` for `willSleep`/`didWake` notifications

### 2. On `willSleep`

- Coordinator captures current window snapshots.
- Captured snapshots are merged with persisted snapshots using per-app freshness:
  keep the latest per-app set when that app was captured at `willSleep`, and only
  use persisted snapshots for apps missing entirely from latest capture.
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
- Retries continue until either:
  - restore succeeds, or
  - retries stagnate (no progress), then the app waits for environment change, or
  - timeout is reached, then the app waits for a concrete environment-change signal to retry.
- Deferred windows are treated in two phases:
  - before any placement progress, Stay keeps interval retries active to allow late AX exposure
  - after placement progress has occurred, repeated deferred no-progress attempts are treated as
    stagnation to avoid visible restore loops
- If stagnation is reached and all remaining failures are deferred-only windows while visible
  windows are already aligned, Stay considers the cycle converged and clears restore state.
- Repeated unchanged residual restore state (`recoverable failures`, `deferred count`,
  `already aligned`) is treated as stagnation even if `moved > 0`, preventing false-progress
  loops where one window keeps reporting as moved without reducing unresolved failures.

Why: OS wake is often earlier than external monitor wake.

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
- For multi-space scenarios, when full WindowServer all-window-list data contains
  more windows than AX for the same app, Stay also merges distinct layer-0 fallback
  windows so windows on non-active Spaces are not silently dropped at capture time.
- Reads each window's frame (`kAXPositionAttribute`, `kAXSizeAttribute`).
- Associates each window with a display ID via screen intersection/nearest-screen fallback.
- Saves app/window identity fields (PID, title, index) and frame.

### Restore

- Groups snapshots by PID.
- Resolves target apps by PID first, then bundle ID / app name remapping when PID is stale.
- Reads current AX windows for each app.
- If an app has no AX windows yet, attempts a temporary app activation nudge and retries
  AX window discovery before deferring to the next retry cycle.
- For multi-window apps, if AX exposes fewer windows than captured snapshots, app restore
  is deferred and retried instead of forcing partial/wrong matches.
- Matches saved snapshots to live windows by title first, then nearest-frame scoring,
  then index fallback.
- Unmatched snapshots are counted as recoverable failures; they are never silently ignored.
- Before writing AX position/size, restore compares current and target frame and skips
  writes for windows that are already aligned within tolerance.
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

## Testing Strategy

Automated tests focus on deterministic logic in `StayCore`:

- Repeated/out-of-order event handling
- Pending restore cancellation on new sleep cycle
- Retry-until-ready behavior
- Timeout fallback behavior
- Restore-failure retry behavior
- Environment-change retrigger behavior after timeout

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
  - richer logging/diagnostics for readiness state
  - optional user-configurable retry/timeout policy
  - launch-at-login and distribution packaging flow
