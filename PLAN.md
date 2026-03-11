# Plan: Full-Cycle Sleep/Wake Automation

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now`: full-cycle sleep/wake scenario automation with wake-only human intervention.

## Objective

- Ensure wake-cycle scenarios run end-to-end with no manual post-wake commands; after wake/login, window discovery, restore, verification, and report generation must run automatically.

## Scenario mapping

- Scenario 2.1 (`finder`): two Finder windows, one per screen, auto-verified after wake/login.
- Scenario 2.2 (`app`): two application windows, one per screen, auto-verified after wake/login.
- Scenario 2.3 (`freecad`): main window on `primary_screen`, child windows on `secondary_screen`, auto-verified after wake/login.
- Scenario 2.4 (`kicad`): main+PCB on `primary_screen`, schematic on `secondary_screen`, auto-verified after wake/login.
- For each scenario, the only user action during cycle execution is waking/unlocking the machine.

## Exit criteria

- `WakeCycleScenarios` supports a single-command full-cycle mode that performs prepare, sleeps the machine, waits through wake/login, then runs verify automatically.
- Automatic verify includes existing readiness gates (display readiness and app/window readiness) and writes a pass/fail report file for the scenario.
- Running full-cycle mode requires no manual `verify` invocation after wake.
- Failures are reported with actionable diagnostics (missing windows, bundle deficits, display mismatch details).
- Existing manual `prepare`/`verify` flow remains available for debugging and does not regress.

## Promotion rule

- Promote this plan when Scenarios 2.1-2.4 pass in full-cycle automation mode with wake-only user intervention across repeated runs and reports confirm deterministic completion.
