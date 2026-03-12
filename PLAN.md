# Plan: Productization

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by turning the current working app into something that can be installed, launched automatically, and distributed predictably.

## Objective

- Land the smallest useful productization slice that improves everyday usability without destabilizing the already-validated window restore behavior.

## Assumptions

- Productization should build on the current validated behavior rather than reopening restore semantics.
- Start-on-login reliability is likely the highest-value productization step, but exact ordering within this item should still be confirmed with the developer before implementation.
- Packaging/signing/notarization work may require machine-specific credentials or manual developer steps outside the repository.

## Scenario mapping

- Stay can be launched from an installed app bundle with recognizable branding and still enters its existing menu-bar flow correctly.
- Stay can be configured to start at login reliably enough for normal daily use without duplicate launches or broken startup state.
- Release packaging/signing/notarization steps are documented or automated well enough that a distributable build can be produced repeatably.

## Exit criteria

- The first productization slice is implemented without regressing the current restore scenarios.
- The chosen productization path is documented clearly enough to support follow-up packaging work.
- Any developer-only manual steps are made explicit instead of being left implicit in the code or tooling.

## Promotion rule

- Promote this plan only after at least one productization improvement is working end-to-end; if signing or distribution work blocks progress, ship the start-on-login/installability slice first and record the remaining release work explicitly.
