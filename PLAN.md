# Plan: Direct Distribution

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by turning the existing bundle/install/notarization work into the supported direct-distribution path for Stay.

## Objective

- Produce the smallest credible direct-download release workflow that preserves Stay's validated runtime behavior and avoids App Store-specific constraints that conflict with Accessibility window control.

## Scenario mapping

- A developer can build, install, notarize, and staple a release-ready `Stay.app` directly from the repository.
- Direct-distribution metadata remains aligned with the installed menu-bar app identity and launch-at-login support.
- Unsupported App Store/TestFlight release paths are removed so the repo reflects the actual supported product goal.

## Exit criteria

- The direct-distribution workflow is documented clearly enough to produce a repeatable notarized release candidate.
- Existing focused bundle and launch-at-login verification remain green after the distribution changes.
- No checked-in docs, tests, or scripts still imply that Mac App Store or TestFlight distribution is supported.

## Promotion rule

- Promote this plan once the repository's documented release path is the notarized direct-download flow and the unsupported App Store/TestFlight path has been removed cleanly.
