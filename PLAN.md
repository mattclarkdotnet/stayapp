# Plan: Apps With Child Windows

## Roadmap Alignment

- `Now`: Apps with child windows (`FreeCAD`, `KiCad`)
- `Next`: Multiple workspaces (out of scope for this plan)
- `Later`: full screen apps, monitor-config changes, productization, complex wake ordering

## Objective

Make capture/restore reliable for real apps that expose child/tool windows that are not consistently represented as standard top-level AX windows.

## Scenario Mapping

- Primary scenario target: `Tests/SCENARIOS.md` Scenario 1.3 (`FreeCAD child windows`).
- Required behavior:
  - main FreeCAD window restores to screen 1
  - FreeCAD child windows (tasks/model/report/python console) restore to screen 2
- Validation order:
  1. manual capture/restore for Scenario 1.3
  2. deterministic fixture/service tests that model Scenario 1.3 edge cases
  3. wake-cycle validation after manual baseline is stable

## Implementation Plan

1. Define child-window restore behavior as explicit rules
- Document how child/tool windows are discovered, filtered, and included in snapshots.
- Keep Finder special-casing isolated; do not apply Finder assumptions to other apps.

2. Strengthen snapshot identity for child windows
- Prefer stable identity (`windowNumber`, role/subrole, title, frame) over index-only matching.
- Ensure missing titles/partial AX exposure still produces deterministic matching decisions.

3. Improve restore assignment and defer policy for partial exposure
- Avoid cross-matching when only a subset of child windows is exposed.
- Defer safely when confidence is low; retry when environment signals indicate more windows are available.

4. Add deterministic tests for FreeCAD/KiCad-like behavior
- Expand fixture/service-level tests for untitled multi-window and child-window sets.
- Add failing regression tests first for each reproduced mismatch before patching.
- Add a deterministic Scenario 1.3-style test that separates main window vs child windows across displays.

5. Add or update real-app scenario coverage
- Use Scenario 1.3 as the baseline acceptance scenario and add KiCad sibling coverage.
- Validate manual capture/restore first, then wake-cycle runs.
- Ensure automated scenario runs visibly move windows (with existing settle pauses) so developers can confirm behavior during execution.

## Exit Criteria

- FreeCAD/KiCad child-window layouts restore correctly in manual capture/restore flows.
- Scenario 1.3 passes with visible main/child window separation across screens after restore.
- Automated scenario execution shows visible window motion and final placement for human confirmation.
- Deterministic tests cover partial AX exposure, untitled child windows, and safe deferral.
- Existing `finder`/`app` baseline scenarios show no regressions.
- `DESIGN.md` and code comments describe child-window policy and boundaries clearly.

## Promotion Rule

When all exit criteria pass, move this roadmap item from `Now` to `Completed`, and promote `Next` (`Multiple workspaces`) into `Now`.
