# Stay Roadmap

## Roadmap Format Rules

- `ROADMAP.md` must always use exactly four sections: `Now`, `Next`, `Later`, and `Completed`.
- `Now` must contain exactly one item (the single active priority).
- `Next` must contain exactly one item (the single queued priority).
- `Later` must contain all remaining items ordered by priority (highest first).
- `Completed` must list finished roadmap items in chronological order (most recent first).
- Completed work must be moved to `Completed`; do not keep completed items in `Now`, `Next`, or `Later`.

## Now

1. Multiple workspaces
- Apps on secondary workspaces should also have their windows restored.
- Implement this with explicit state-machine transitions in `StayCore` and workspace-aware pending restore sets, not ad-hoc branching.
- Keep restore behavior idempotent and bounded under repeated `activeSpaceDidChange` signals.

## Next

1. Full screen apps
- Full-screen apps should remain on their target display, and Stay should avoid interfering with full-screen placement behavior.

## Later

1. Changes in monitor configuration between sleep and wake
- It's OK to do nothing; we just don't want to crash or cause any unexpected window movements.
2. Productization
- App icon and branding assets.
- Start-on-login hardening.
- Packaging/signing/notarization/distribution workflows.
3. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).


## Completed

1. Code cleanup and baseline hardening
- Split `WakeCycleScenarios` into focused support modules and `WakeCycleScenariosCore`.
- Added codec/parser/metadata persistence tests, malformed-decode coverage, and deterministic idempotence/retry tests.
- Hardened fallback merge semantics for apps explicitly observed with zero windows.
- Reduced FreeCAD real-app scenario flakiness with relaunch retry during readiness.

2. Full-cycle sleep/wake scenario automation (wake-only human intervention)
- Wake-cycle scenarios now support automated post-wake verification with no manual `verify` command in the default cycle flow.

3. Apps with child windows
- FreeCAD child windows and KiCad split-editor windows restore correctly in automated scenarios.

4. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

5. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
