# Plan: Code Cleanup And Consolidation

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now`: code cleanup and consolidation before starting workspace-specific behavior.

## Objective

- Reduce complexity and drift by aligning documentation with actual behavior, extracting repeated logic into focused helpers/modules, and adding targeted tests/comments so the current wake-cycle baseline remains stable while code becomes easier to extend.

## Scenario mapping

- Scenario 1.1 / 1.2 (`finder`, `app` no-sleep): preserve deterministic capture/restore behavior while refactoring.
- Scenario 1.3 / 1.4 (`freecad`, `kicad` no-sleep): preserve child-window and split-editor placement behavior while extracting common matching/movement helpers.
- Scenario 2.1-2.4 (`cycle` wake/sleep): preserve automated full-cycle verification and report generation while cleaning orchestration and helper boundaries.
- Cross-scenario focus: document and test the shared readiness/matching pipeline used by manual `verify` and `cycle` verify paths.

## Exit criteria

- `DESIGN.md`, `TESTING.md`, and `Tests/TESTS.md` accurately describe the implemented `WakeCycleScenarios` command set and execution behavior.
- Repeated logic in `WakeCycleScenarios` is extracted into smaller helpers/types with clear responsibilities and stable interfaces.
- Public methods have docstrings; internal methods have concise intent comments where behavior is non-obvious.
- Unit/integration coverage is expanded for newly extracted logic (especially readiness gating and cycle-state transitions).
- Existing baseline checks remain green and no regression is observed in manual runs for `app` and `kicad` cycle scenarios.

## Promotion rule

- Promote this plan when documentation drift is eliminated, refactoring lands with passing tests, and baseline scenario behavior remains unchanged across no-sleep and wake-cycle flows.
