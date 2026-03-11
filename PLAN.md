# Plan: Multiple Workspace Restore

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by adding workspace-aware restore behavior while preserving existing wake-cycle and no-sleep stability guarantees.

## Objective

- Add deterministic multi-workspace window restoration using explicit state-machine transitions and workspace-scoped pending snapshot tracking so windows in inactive spaces are restored when their space becomes active.

## Scenario mapping

- Scenario 1.1 / 1.2 (`finder`, `app` no-sleep): keep current behavior unchanged on a single active workspace while proving restore remains idempotent.
- Scenario 1.3 / 1.4 (`freecad`, `kicad` no-sleep): preserve child-window/split-editor matching while introducing workspace-scoped retry state.
- Scenario 2.1-2.4 (`cycle` wake/sleep): extend wake orchestration so deferred windows are partitioned by active workspace and retried only when relevant workspace signals arrive.
- Working assumption: windows keep their workspace identity across sleep/wake; restore logic only needs to react to active-workspace visibility changes at restore time.
- Implementation detail: add a workspace-aware pending model in `StayCore` that partitions unresolved snapshots into `active-workspace` and `inactive-workspace` subsets, with explicit transitions for `didWake`, `activeSpaceDidChange`, timeout, and completion.
- Implementation detail: extend restore result/accounting to report workspace progress (resolved now vs deferred to other workspace) so coordinator decisions are based on typed state rather than implicit counts.
- Implementation detail: keep all workspace policy in `StayCore`; `Stay` layer only emits environment/workspace-change signals.

## Exit criteria

- `SleepWakeCoordinator` uses explicit workspace-aware state transitions (documented in `DESIGN.md`) instead of ad-hoc branching for active-space retries.
- Deterministic tests cover:
  - windows deferred to inactive workspace are not repeatedly retried on interval,
  - `activeSpaceDidChange` retriggers only relevant pending workspace snapshots,
  - repeated workspace-change noise does not create unbounded retry loops,
  - already-restored workspace snapshots remain no-op on subsequent signals.
- Existing baseline test gates remain green:
  - `swift test --filter StayCoreTests`
  - `swift test --filter WakeCycleScenariosCoreTests`
  - `swift test --filter WindowRoundTripTests`
  - repeated `STAY_REALAPP_VISUAL_PAUSE=0 swift test --filter RealAppScenarioTests`
- `TESTING.md` and `Tests/TESTS.md` describe the workspace model, expected retry behavior, and known limits.

## Promotion rule

- Promote this plan only when multi-workspace behavior is validated by deterministic coordinator tests plus repeated real-app runs, with no regression to single-workspace scenarios and no known workspace-retry flake path.
