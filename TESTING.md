# Testing Strategy

## Principles

- Any failing tests must be captured as new test cases, whether they come from compilation, user feedback, or unexpected behavior.
- Tests must be kept in sync with functional code.
- Do not keep tests that are no longer relevant
- Focus on common paths first
- Add explicit tests for edge cases that are universal across all kinds of apps:
  - Repeated events
  - Unparseable inputs
  - Unexpected delays
  - App termination
  - Data values not expected
- Consider property testing for core code logic

## Purpose

Stay handles OS sleep/wake timing, multi-display behavior, and Accessibility APIs.
The testing approach is layered so we can get fast confidence from automation while
still validating real hardware behavior with human-in-loop QA.


## Test Layers

### 1. Unit Tests (fast, deterministic)

Scope:

- `StayCore` state machine and retry logic (`SleepWakeCoordinator`)
- event ordering and idempotency (duplicate wake, wake-before-sleep, repeated sleep)
- persistence fallback behavior
- readiness and restore retry interactions

Why:

- deterministic and cheap to run on every change
- no dependence on actual sleep cycles or monitor hardware

Gate:

- must pass for every change set (`swift test`)

### 2. Integration Tests (scripted/system-level, still mostly automated)

Scope:

- end-to-end app process startup
- notification wiring (`willSleep`, `didWake`, session/space/screen change observers)
- logging and diagnostics behavior
- sanity checks around snapshot persistence path and format

How:

- use manual trigger paths from the menu (`Capture Layout Now`, `Restore Layout Now`)
- run with live logs (`log stream --predicate 'subsystem == "com.stay.app"'`)
- verify restore loops and error handling when AX operations fail transiently

Limitations:

- true monitor wake timing and lock-screen transitions remain difficult to fully automate

### 3. Human-in-Loop QA (real hardware, real sleep cycle)

Scope:

- full sleep -> wake -> login flow
- external monitor low-power transitions
- multi-display + multi-space combinations
- app-specific behavior (Safari/Preview/Finder/etc.)

Recommended matrix:

- laptop open vs clamshell
- one external vs two or more external displays
- single space vs multiple spaces
- locked wake (login required) vs unlocked wake

Acceptance criteria:

- windows that were on secondary displays before sleep return to those displays after wake
- no persistent restore loop after success
- logs show sensible retries and eventual success or timeout behavior

## Diagnostics-Driven Testing

Use logs as first-class test evidence:

- observer events occurred in expected order
- capture count and merged snapshot count are plausible
- readiness checks match actual display state transitions
- restore failures include AX error codes and retry decisions

When failures occur, attach the `stay-wake.log` excerpt with timestamps.

## Practical Workflow

1. Run `swift test` locally.
2. Run app, exercise manual capture/restore sanity checks.
3. Run one or more real sleep/wake QA scenarios.
4. Review logs for retries, readiness transitions, and final success conditions.
5. Record any hardware/app-specific regressions with logs and repro steps.
