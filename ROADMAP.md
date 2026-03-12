# Stay Roadmap

## Now

1. The same display is disconnected and reconnected while the system is awake
- If a display disappears and then the same display comes back while Stay is still running, windows should end up where they were before the disconnect.

## Next

1. Changes in monitor configuration between sleep and wake
- Handle the harder case where a missing display during restore may be a real topology change or just a slow wake.
- It's OK to do nothing; we just don't want to crash or cause any unexpected window movements.

## Later

1. Productization
- App icon and branding assets.
- Start-on-login hardening.
- Packaging/signing/notarization/distribution workflows.
2. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).
3. Replacement secondary displays inherit prior secondary-display windows
- If one secondary display is disconnected and a different secondary display is connected later, Stay should move windows that were previously assigned to the removed secondary display onto the newly connected secondary display.

## Completed

1. Changes in monitor configuration while the system is awake
- If a display disappears while Stay is awake, Stay now invalidates stale persisted and queued in-memory snapshots for that display so later restores do not target it.

2. Separate spaces setting pauses Stay
- When macOS `Displays have separate Spaces` is enabled, Stay stands down at launch, disables manual capture/restore, and sends a best-effort notification that macOS is handling placement until the setting changes again.

3. Full screen apps
- Full-screen windows are excluded from the restorable snapshot set, and real-app coverage proves normal restore scenarios ignore them.

4. Multiple workspaces
- Apps on secondary workspaces are restored with explicit workspace-aware pending state in `StayCore`.
- Added no-sleep and full wake-cycle scenario coverage for secondary-workspace TextEdit restores.

5. Code cleanup and baseline hardening
- Split `WakeCycleScenarios` into focused support modules and `WakeCycleScenariosCore`.
- Added codec/parser/metadata persistence tests, malformed-decode coverage, and deterministic idempotence/retry tests.
- Hardened fallback merge semantics for apps explicitly observed with zero windows.
- Reduced FreeCAD real-app scenario flakiness with relaunch retry during readiness.

6. Full-cycle sleep/wake scenario automation (wake-only human intervention)
- Wake-cycle scenarios now support automated post-wake verification with no manual `verify` command in the default cycle flow.

7. Apps with child windows
- FreeCAD child windows and KiCad split-editor windows restore correctly in automated scenarios.

8. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

9. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
