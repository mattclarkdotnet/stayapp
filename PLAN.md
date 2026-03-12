# Plan: Monitor Configuration Changes

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by defining the smallest safe behavior when monitor topology changes between sleep and wake: Stay must not crash and must not cause unexpected window moves.

## Objective

- Prove the narrow acceptance case first with deterministic coverage for missing or remapped displays, and only add smarter remapping behavior if a concrete failing reproducer shows the simple safe path is insufficient.

## Scenario mapping

- Exercise Scenario 2.1 / 2.2 with deterministic fixtures where a saved display is missing at restore time, and verify Stay does not crash or force windows onto incorrect screens.
- Add coverage for manual restore when saved display identifiers no longer map cleanly after wake.
- If the safe-path behavior still exposes a concrete user-visible failure, add the narrowest reproducer that distinguishes missing-display handling from wake-order timing.

## Exit criteria

- Stay tolerates changed monitor topology between sleep and wake without crashing.
- Stay does not move windows onto unexpected displays when saved display identifiers are missing or remapped.
- Deterministic automated coverage exists for the chosen safe behavior before production changes are promoted.
- Relevant docs describe the expected degraded behavior and any remaining human QA gaps.

## Promotion rule

- Promote this plan only after the smallest "do no harm" behavior is automated first; only add more ambitious remapping once a failing reproducer proves it is necessary.
