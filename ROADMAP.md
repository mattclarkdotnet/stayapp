# Stay Roadmap

## Now

1. Polish and quality of user experience
- Tighten first-run, installed-app, and menu-bar behavior so Stay feels coherent as a product rather than just a validated prototype.
- Improve clarity of status messaging, prompts, and recovery paths without changing the core restore model.

## Next

1. Replacement secondary displays inherit prior secondary-display windows
- If one secondary display is disconnected and a different secondary display is connected later, Stay should move windows that were previously assigned to the removed secondary display onto the newly connected secondary display.

## Later

1. Edge cases for awake-time same-display reconnect are hardened
- Repeated disconnect/reconnect cycles should not duplicate queued restore work or restore the wrong snapshot generation.
- Multi-window apps should converge cleanly if macOS temporarily bunches their windows onto the primary display before the original secondary display comes back.
2. Laptop with open built-in display and one external display
- Handle restore behavior cleanly when the built-in display remains active and a single external display is also attached.
- Verify that capture, restore, and display matching stay predictable when the menu bar or primary display may move between the internal and external screens.
3. Laptop with open built-in display and two external displays
- Handle restore behavior cleanly when the built-in display remains active alongside two external displays.
- Verify that display matching remains stable when the internal panel participates in a three-display topology.
4. Complex wake ordering is handled explicitly
- Handle screens waking in different orders.
- Handle login occurring while only one screen is active.
- Implement this with explicit state machines in `StayCore` (no ad-hoc procedural branching).

## Completed

1. Direct distribution
- Stay now has a supported Developer ID and notarization-based release path for the full Accessibility-driven product, with App Store/TestFlight work removed from the roadmap because App Sandbox conflicts with Stay's core window-management behavior.

2. Start on login as early as macOS allows
- Stay now exposes a user-controlled `Launch At Login` menu item backed by `SMAppService.mainApp`, and the installed notarized `/Applications/Stay.app` can be enabled successfully in Login Items without duplicate instances.

3. Bundling and installability
- Stay now has checked-in app-bundle metadata plus build/install scripts that stage `dist/Stay.app` and install it into `/Applications` as a normal launchable app bundle.

4. Changes in monitor configuration between sleep and wake
- If a saved display is still missing after wake, Stay now keeps those windows deferred instead of remapping them onto a different display, and it retries when later wake-session environment changes indicate the display may have returned.

5. The same display is disconnected and reconnected while the system is awake
- If a display disappears and then the same display comes back while Stay is still running, Stay now restores windows to the original display after it returns.

6. Changes in monitor configuration while the system is awake
- If a display disappears while Stay is awake, Stay now invalidates stale persisted and queued in-memory snapshots for that display so later restores do not target it.

7. Separate spaces setting pauses Stay
- When macOS `Displays have separate Spaces` is enabled, Stay stands down at launch, disables manual capture/restore, and sends a best-effort notification that macOS is handling placement until the setting changes again.

8. Full screen apps
- Full-screen windows are excluded from the restorable snapshot set, and real-app coverage proves normal restore scenarios ignore them.

9. Multiple workspaces
- Apps on secondary workspaces are restored with explicit workspace-aware pending state in `StayCore`.
- Added no-sleep and full wake-cycle scenario coverage for secondary-workspace TextEdit restores.

10. Code cleanup and baseline hardening
- Split `WakeCycleScenarios` into focused support modules and `WakeCycleScenariosCore`.
- Added codec/parser/metadata persistence tests, malformed-decode coverage, and deterministic idempotence/retry tests.
- Hardened fallback merge semantics for apps explicitly observed with zero windows.
- Reduced FreeCAD real-app scenario flakiness with relaunch retry during readiness.

11. Full-cycle sleep/wake scenario automation (wake-only human intervention)
- Wake-cycle scenarios now support automated post-wake verification with no manual `verify` command in the default cycle flow.

12. Apps with child windows
- FreeCAD child windows and KiCad split-editor windows restore correctly in automated scenarios.

13. Basic scenarios work across wake cycles
- Validated with real `WakeCycleScenarios` runs for both `finder` and `app`.

14. Basic scenarios are automated
- Automated scenarios in `Tests/SCENARIOS.md` use real apps and move real windows.
