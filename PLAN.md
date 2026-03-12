# Plan: Separate Spaces Compatibility

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by determining whether enabling macOS `Displays have separate Spaces` needs any product changes, starting with the smallest plausible outcome: existing behavior already works and only explicit coverage/docs are missing.

## Objective

- Test the simple hypothesis first by running focused real-app scenarios with `Displays have separate Spaces` enabled, and only add code if those probes expose a concrete capture/restore failure.

## Scenario mapping

- Probe Scenario 1.1 / 1.2 first under `Displays have separate Spaces = ON`: if standard two-window Finder/TextEdit restore still works unchanged, treat that as evidence that the simple path may be sufficient.
- If the simple probe passes, add explicit scenario coverage and documentation for the enabled-setting case before broadening scope.
- If the simple probe fails, add the narrowest reproducer that distinguishes whether the problem is capture, restore matching, display-ID mapping, or workspace/space-selection behavior.
- Only after a reproduced failure should the plan expand to workspace-aware or per-display-space policy changes in production code.

## Exit criteria

- The repo documents how `Displays have separate Spaces` is expected to behave and what has been verified.
- At least one automated or repeatable real-app probe exists for the enabled-setting case, starting with the unchanged-behavior hypothesis.
- If probes pass, the item may complete with scenario coverage plus docs only.
- If probes fail, a failing automated test/reproducer exists before any production-code fix is promoted.
- Baseline verification for whatever path is taken remains green:
  - `swift test --filter StayIntegrationTests.RealAppScenarioTests`
  - `swift test --filter WindowRoundTripTests`
  - targeted wake-cycle runs if the enabled-setting probe reaches sleep/wake scope

## Promotion rule

- Promote this plan only after the simple no-code hypothesis has been tested first and either accepted with explicit coverage or rejected with a narrowly scoped failing reproducer that justifies deeper changes.
