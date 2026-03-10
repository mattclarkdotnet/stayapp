# Plan: Manual-First Restore Baseline

## Roadmap Item

Manual Capture/Restore Reliability

## Objective

Make simple, manually invoked capture/restore flows reliable before investing in sleep/wake-specific hardening.

## Execution Plan

1. Establish Manual Baseline Scenarios
- Define and repeatedly validate the minimum manual scenarios:
  - single-window restore
  - two-window/two-display restore
  - Finder-specific dual-window restore
- Treat failures here as blockers for further wake-flow work.

2. Fix Core Matching/Placement Gaps
- Prioritize deterministic manual restore correctness over retry policy tuning.
- Keep app-specific behavior isolated and documented (for example Finder quirks).
- Improve observability for unmatched windows and frame-write failures during manual runs.

3. Codify Baseline in Tests
- Add/expand deterministic tests that model each manual baseline scenario.
- For each reproduced regression, add a failing test before patching.
- Keep test focus on logic that does not require real sleep cycles.

4. Reintroduce Sleep/Wake Scenarios
- Once manual baseline + tests are stable, validate full wake orchestration.
- Only then revisit advanced retry/cooldown tuning for non-converging windows.

## Success Criteria

- Manual capture/restore works for baseline scenarios without ad-hoc operator intervention.
- Baseline scenarios are covered by automated tests and stay green.
- Sleep/wake tuning work starts only after manual baseline reliability is demonstrated.

## Next Planning Note

- After the current baseline is locked, prioritize complex wake/login timing cases:
  - displays waking in different orders
  - login completed while only one display is active
- Model these flows with explicit state machines in `StayCore`; do not add ad-hoc branching logic.
