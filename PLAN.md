# Plan: Baseline Stability Hardening

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by hardening the current capture/restore and wake-cycle baseline so future workspace/fullscreen/monitor-topology work builds on proven stable behavior.

## Objective

- Convert the current implementation from “working” to “reliably predictable” by locking down deterministic behavior, codifying failure handling, and enforcing repeatable test gates before any new feature scope is started.

## Scenario mapping

- Scenario 1.1 / 1.2 (`finder`, `app` no-sleep): enforce idempotent restore behavior (`restore` after already-correct placement is a no-op) and stable window matching across repeated perturb/restore loops.
- Scenario 1.3 / 1.4 (`freecad`, `kicad` no-sleep): enforce stable child-window/editor assignment, preserve size when required, and verify deterministic placement ordering when multiple windows share weak titles.
- Scenario 2.1-2.4 (`cycle` wake/sleep): enforce deterministic cycle-state transitions (`prepare -> armed -> resumed/verifying -> completed|failed`) under delayed display readiness and repeated wake/session signals.
- Cross-scenario hardening: explicitly test “running app with zero open windows,” transient AX frame-write failures, and missing/offline display conditions so retries/deferred handling stay bounded and non-destructive.
- Cross-scenario persistence: verify scenario/cycle state codecs are backward-compatible with existing persisted files and fail safely (clear diagnostics, no crashes, no stale-state loops) on malformed data.

## Exit criteria

- `DESIGN.md`, `TESTING.md`, and `Tests/TESTS.md` describe the exact implemented behavior for capture, prepare/verify, cycle/resume, persistence, and failure handling (no drift).
- `WakeCycleScenariosCoreTests` includes explicit coverage for invocation parsing, scenario metadata, scenario/cycle persistence codecs, and malformed-input decode failures.
- Deterministic tests cover: no-open-window apps, deferred-only residual behavior, retry stagnation boundaries, and restore no-op behavior when windows are already aligned.
- Real-app baseline remains green with `STAY_REALAPP_VISUAL_PAUSE=0 swift test --filter RealAppScenarioTests`, and no regressions are observed in Finder/TextEdit/FreeCAD/KiCad scenarios.
- Public APIs touched by this roadmap item have docstrings, and internal non-obvious flow-control methods include intent comments explaining why behavior is constrained.

## Promotion rule

- Promote `Now` only when deterministic/unit gates and real-app baseline gates both pass with no known flaky paths, and the documented behavior matches the implementation exactly enough to support multi-workspace work without reopening baseline bugs.
