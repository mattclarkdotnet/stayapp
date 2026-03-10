# Stay Roadmap

## Roadmap Format Rules

- `ROADMAP.md` must always use exactly four sections: `Now`, `Next`, `Later`, and `Completed`.
- `Now` must contain exactly one item (the single active priority).
- `Next` must contain exactly one item (the single queued priority).
- `Later` must contain all remaining items ordered by priority (highest first).
- `Completed` must list finished roadmap items in chronological order (most recent first).
- Completed work must be moved to `Completed`; do not keep completed items in `Now`, `Next`, or `Later`.

## Now

1. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).

## Next

1. Multiple workspaces

## Later

1. Apps with child windows
2. Full screen apps
3. Changes in monitor configuration between sleep and wake (default: do nothing)
4. Productization
- App icon and branding assets.
- Start-on-login hardening.
- Packaging/signing/notarization/distribution workflows.

## Completed

1. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

2. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
