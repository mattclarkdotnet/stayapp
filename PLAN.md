# Plan: Complex Wake/Login Ordering

## Roadmap Alignment

- `Now`: Complex wake ordering is handled explicitly.
- `Next`: Multiple workspaces (out of scope for this plan).
- `Later`: child windows, full screen apps, monitor-config changes, productization.

## Objective

Handle wake sequences where displays become available in different orders, including login with only one active display, using explicit `StayCore` state machines (not ad-hoc branching).

## Implementation Plan

1. Define the wake sequencing state machine in `StayCore`
- Introduce explicit states for: pre-sleep captured, waking/not-ready, partial-display-ready, restoring, waiting-for-environment-change, completed.
- Define typed transition events for: `willSleep`, `didWake`, `screensDidWake`, session active/inactive, display readiness changes, timeout.

2. Move orchestration decisions behind state transitions
- Keep policy in a reducer-style transition function.
- Keep side effects (capture/restore/schedule) in the imperative shell.
- Remove ad-hoc conditional flow that duplicates transition logic.

3. Add deterministic tests for wake-order permutations
- Two displays wake in order A->B and B->A.
- Login occurs before second display is online.
- Duplicate/repeated wake and readiness events.
- Timeout followed by later environment change.

4. Add deterministic fuzz + replay harness for event ordering
- Generate seeded pseudo-random event traces (`willSleep`, `didWake`,
  environment changes, scheduler ticks).
- Assert invariants on every trace:
  - no restore before a sleep cycle
  - at most one scheduled restore task at a time
  - pending restore snapshot sets never grow within a wake cycle
  - coordinator reaches quiescence (no scheduled retries) after bounded ticks
- Persist failing seeds/traces as fixed regression tests.

5. Validate in real scenarios
- Run `WakeCycleScenarios` for `finder` and `app` through multiple wake cycles.
- Confirm no restore thrash and correct final placement after delayed display availability.

## Exit Criteria

- State machine transitions are explicit and documented in `DESIGN.md`.
- New tests cover wake-order and single-display-login permutations.
- `finder` and `app` wake-cycle scenarios remain stable.
- No new ad-hoc wake-flow branches are introduced outside state transitions.

## Promotion Rule

When all exit criteria pass, move this roadmap item from `Now` to `Completed`, and promote `Next` (`Multiple workspaces`) into `Now`.
