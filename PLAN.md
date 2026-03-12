# Plan: Start On Login As Early As macOS Allows

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by building login-item support on top of the newly installed `Stay.app` bundle identity.

## Objective

- Launch Stay automatically as early as macOS allows after login, without introducing duplicate launches or destabilizing the existing restore behavior.

## Assumptions

- Login-item registration should target the installed app bundle rather than a SwiftPM build artifact.
- "As early as macOS allows" means using the supported login-item mechanism correctly, not trying to out-race every other app with unsupported startup hacks.
- Distribution concerns remain out of scope for this plan unless they block local login-item verification.

## Scenario mapping

- The user installs `Stay.app`, enables launch at login, logs out, and logs back in; Stay starts automatically without manual relaunch.
- Login-item registration remains stable across repeated app launches and does not create duplicate Stay processes.
- The login-item path preserves the existing menu-bar-only behavior and still respects the separate-spaces suspension policy at launch.

## Exit criteria

- Stay can be enabled for automatic login launch from the installed app bundle and starts reliably after login.
- The chosen login-item behavior is documented clearly enough for the later distribution roadmap item to build on it.
- Existing focused restore verification remains green after the login-item changes.

## Promotion rule

- Promote this plan only after login launch works end-to-end from the installed bundle; if App Store/TestFlight constraints become the main blocker, record them and move on to the separate distribution roadmap item.
