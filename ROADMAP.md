# Stay Roadmap

## Roadmap Format Rules

- `ROADMAP.md` must always use exactly four sections: `Now`, `Next`, `Later`, and `Completed`.
- `Now` must contain exactly one item (the single active priority).
- `Next` must contain exactly one item (the single queued priority).
- `Later` must contain all remaining items ordered by priority (highest first).
- `Completed` must list finished roadmap items in chronological order (most recent first).
- Completed work must be moved to `Completed`; do not keep completed items in `Now`, `Next`, or `Later`.

## Now

1. Code cleanup
- Ensure consistency between docs and code by updating the docs to match the code (IMPORTANT! the docs should be updated to make things consistent, not the code)
- Factor out common functionality to separate classes/modules
- Add type aliases for common types
- Improve unit test coverage
- Add comments to all methods (not docstrings)
- Add docstrings to all public methods

## Next

1. Multiple workspaces
- Apps on secondary workspaces should also have their windows restored

## Later

1. Full screen apps
- full screen apps should remain on their target display, Stay.app should not interfere.
2. Changes in monitor configuration between sleep and wake
- it's OK to do nothing, we just don't want to crash or cause any unexpected window movements
3. Productization
- App icon and branding assets.
- Start-on-login hardening.
- Packaging/signing/notarization/distribution workflows.
4. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).


## Completed

1. Full-cycle sleep/wake scenario automation (wake-only human intervention)
- Wake-cycle scenarios now support automated post-wake verification with no manual `verify` command in the default cycle flow.

2. Apps with child windows
- FreeCAD child windows and KiCad split-editor windows restore correctly in automated scenarios.

3. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

4. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
