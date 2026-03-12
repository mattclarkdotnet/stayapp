# Plan: Distribution

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by turning the notarized local app bundle flow into a repeatable distribution path, starting with TestFlight-facing requirements and then App Store delivery.

## Objective

- Produce the smallest credible release pipeline that moves Stay from a locally installable notarized app toward real distribution without destabilizing the validated runtime behavior, while assuming TestFlight/App Store work will need extra metadata, entitlements, and App Store Connect decisions beyond the current local notarized Developer ID flow.

## Scenario mapping

- A release build can be produced from the repository with the signing/trust properties required for external distribution.
- Distribution-specific metadata and packaging choices remain aligned with the current menu-bar-only app behavior and login-item support.
- The path to TestFlight is explicit, and any App Store-specific gaps are documented rather than being left implicit.

## Exit criteria

- The distribution workflow is documented clearly enough to produce a repeatable release candidate.
- Existing focused restore and login-item verification remain green after the distribution changes.
- Any remaining App Store or TestFlight blockers are captured explicitly if they cannot be solved in the first slice.

## Promotion rule

- Promote this plan only after at least one real distribution path is proven end-to-end; if App Store requirements exceed the first slice, finish the TestFlight-ready path and record the remaining App Store work explicitly.
