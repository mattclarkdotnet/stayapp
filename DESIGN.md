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
- If stagnation is reached and all remaining failures are deferred-only windows, Stay enters a
  deferred-space wait mode (no interval retries) and waits for environment changes
  (for example, active-space switch) before retrying.
- In deferred-space wait mode, retries are gated to active-space change notifications to avoid
  wake/session noise retriggering unnecessary restores.
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
If deferred snapshots remain, timeout capping is bypassed and Stay keeps pending work for
later active-space changes.

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
- Deferred-only residual windows remain pending so later space changes can complete restore.

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
