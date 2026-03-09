# Wake Restore Refactor Plan

## Goal

Make wake restore deterministic for currently accessible windows by reducing global retry complexity and preventing repeated movement of windows that have already been restored.

## Observed Failure Modes (from recent logs)

- Repeated retries move or attempt to move the same windows multiple times, causing visible flashing.
- Multi-window apps (FreeCAD/KiCad/Preview) often expose only a subset of AX windows until later.
- Partial app exposure leads to repeated partial restore behavior and unstable outcomes.
- Aggregate restore counters are too coarse to drive deterministic retry pruning.

## Phase 1 (this change set)

1. Introduce per-snapshot restore progress:
- Extend restore results to report which snapshots are resolved on each attempt.
- Treat "resolved" as moved+converged or already aligned.

2. Prune resolved snapshots from pending wake work:
- Coordinator keeps only unresolved snapshots for subsequent retries.
- Already restored snapshots are not touched again in the same wake cycle.

3. Preserve existing readiness and timeout behavior:
- Keep current display readiness and deadline model.
- Keep environment-triggered retry path.

4. Keep current cross-space limitations explicit:
- Do not attempt to solve "restore windows in inactive spaces" in phase 1.
- Continue to rely on environment change signals for newly exposed windows.

5. Add automated tests for pruning semantics:
- Verify retries receive only unresolved snapshots.
- Verify cycles end once all pending snapshots are resolved.

## Phase 2 (current change set)

1. Space-aware restore strategy:
- Avoid touching windows that are not currently restorable in the active space.
- Restore deferred windows when their space becomes active.

2. Activation policy simplification:
- Revisit/limit app activation during automatic wake restore to reduce flashing.

3. Snapshot schema enrichment:
- Add stronger window identity metadata for difficult multi-window apps.

## Phase 2 Status

- Implemented:
  - Snapshot identity enrichment (`windowNumber`, role/subrole metadata).
  - Active-space partitioning during restore using on-screen WindowServer window numbers.
  - Deferred-space coordinator mode: deferred snapshots park and retry on
    `activeSpaceDidChange` instead of terminating or interval-looping.
  - Activation policy tightened: avoid force-activating multi-window apps during wake restore.
  - Timeout-cap behavior refined: if deferred snapshots remain, keep pending state for later
    active-space retries instead of clearing restore state early.
- Deferred:
  - Per-app exceptions for apps that do not expose stable window numbers (for example, KiCad).

## Success Criteria

- In one wake cycle, each resolved window is restored at most once.
- Repeated restore attempts only target unresolved windows.
- Logs show shrinking pending snapshot count as progress is made.
- No regression in current unit/integration test suites.
