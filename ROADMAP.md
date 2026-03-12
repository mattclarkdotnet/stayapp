# Stay Roadmap

## Now

1. Distribution
- Prepare Stay for TestFlight distribution first, then App Store distribution.
- Capture the packaging/signing requirements separately from installability so release work can progress without blocking local productization.

## Next

1. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).

## Later

1. Replacement secondary displays inherit prior secondary-display windows
- If one secondary display is disconnected and a different secondary display is connected later, Stay should move windows that were previously assigned to the removed secondary display onto the newly connected secondary display.
2. Edge cases for awake-time same-display reconnect are hardened
- Repeated disconnect/reconnect cycles should not duplicate queued restore work or restore the wrong snapshot generation.
- Multi-window apps should converge cleanly if macOS temporarily bunches their windows onto the primary display before the original secondary display comes back.

## Completed

1. Start on login as early as macOS allows
- Stay now exposes a user-controlled `Launch At Login` menu item backed by `SMAppService.mainApp`, and the installed notarized `/Applications/Stay.app` can be enabled successfully in Login Items without duplicate instances.

2. Bundling and installability
- Stay now has checked-in app-bundle metadata plus build/install scripts that stage `dist/Stay.app` and install it into `/Applications` as a normal launchable app bundle.

3. Changes in monitor configuration between sleep and wake
- If a saved display is still missing after wake, Stay now keeps those windows deferred instead of remapping them onto a different display, and it retries when later wake-session environment changes indicate the display may have returned.

4. The same display is disconnected and reconnected while the system is awake
- If a display disappears and then the same display comes back while Stay is still running, Stay now restores windows to the original display after it returns.

5. Changes in monitor configuration while the system is awake
- If a display disappears while Stay is awake, Stay now invalidates stale persisted and queued in-memory snapshots for that display so later restores do not target it.

6. Separate spaces setting pauses Stay
- When macOS `Displays have separate Spaces` is enabled, Stay stands down at launch, disables manual capture/restore, and sends a best-effort notification that macOS is handling placement until the setting changes again.

7. Full screen apps
- Full-screen windows are excluded from the restorable snapshot set, and real-app coverage proves normal restore scenarios ignore them.

8. Multiple workspaces
- Apps on secondary workspaces are restored with explicit workspace-aware pending state in `StayCore`.
- Added no-sleep and full wake-cycle scenario coverage for secondary-workspace TextEdit restores.

9. Code cleanup and baseline hardening
- Split `WakeCycleScenarios` into focused support modules and `WakeCycleScenariosCore`.
- Added codec/parser/metadata persistence tests, malformed-decode coverage, and deterministic idempotence/retry tests.
- Hardened fallback merge semantics for apps explicitly observed with zero windows.
- Reduced FreeCAD real-app scenario flakiness with relaunch retry during readiness.

10. Full-cycle sleep/wake scenario automation (wake-only human intervention)
- Wake-cycle scenarios now support automated post-wake verification with no manual `verify` command in the default cycle flow.

11. Apps with child windows
- FreeCAD child windows and KiCad split-editor windows restore correctly in automated scenarios.

12. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

13. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
