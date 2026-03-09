# Stay Roadmap

## Priority Order

1. Manual Capture/Restore Reliability (Now)
- Make simple, user-invoked capture/restore paths work consistently before further wake-cycle hardening.
- Treat this as the baseline acceptance gate for all matching and placement logic.
- Start with concrete manual scenarios:
  - one window on one display
  - two windows across two displays
  - Finder-specific quirks (documented and isolated from general app behavior)
- Exit criteria:
  - manual capture followed by manual restore reliably returns windows to expected displays/frames
  - logs clearly explain why any window could not be restored

2. Automate Manual Scenarios (Next)
- Convert each validated manual scenario into deterministic automated tests.
- For every regression found in logs, add a failing test first, then patch behavior.
- Expand fixture coverage for ambiguous matching and partial exposure cases.
- Exit criteria:
  - `swift test` covers the manual baseline scenarios and regressions
  - baseline behavior is preserved by tests before wake-flow changes

3. Sleep/Wake End-to-End Reliability (Then)
- Apply the proven manual restore logic to full sleep/wake orchestration.
- Revisit readiness timing, retries, and deferred-space behavior only after manual baseline is stable.
- Validate on real hardware sleep/wake cycles as QA-only scenarios.
- Exit criteria:
  - manual baseline remains stable
  - real sleep/wake restores pass QA scenarios without regressions

## Deferred Until Baseline Is Stable

1. Advanced Restore Hardening
- Cooldowns/backoff for repeated non-convergence.
- Additional retry-thrash reduction policies.

2. Productization
- App icon and branding assets.
- Start-on-login hardening.
- Packaging/signing/notarization/distribution workflows.
