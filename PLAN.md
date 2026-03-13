# Plan: Polish And Quality Of User Experience

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by turning the first product-polish slice into concrete installed-app behavior after direct distribution has already been completed.

## Objective

- Produce the smallest credible UX-polish slice that makes the installed app feel deliberate and understandable, with sensible default startup behavior and a cleaner menu-bar interaction model, without destabilizing the validated capture, restore, and distribution behavior.

## Assumptions

- This slice should stay focused on the installed app's menu-bar experience rather than broad changes to restore logic.
- Defaulting `Launch At Login` on should happen only when Stay is running from a real installed app bundle, while still leaving opt-out obvious and user-controlled.
- Snapshot inspection can be read-only in the first slice; it does not need editing, export, or per-window actions yet.

## Scenario mapping

- A first launch or freshly installed launch enables `Launch At Login` by default, while still exposing an obvious menu control for turning it off again.
- The menu bar uses an icon rather than text-only status so Stay reads like a normal installed macOS menu-bar app.
- The menu makes Stay's current operating state explicit, showing whether it is `ready` or `paused` so the user does not have to infer that from missing behavior.
- Existing pause behavior for `Displays have separate Spaces` remains visible in the menu as a paused state, not just as a one-time notification after launch.
- Manual power-user actions move under an `Advanced` submenu, with `Capture Layout Now` and `Restore Layout Now` no longer competing with the primary status and settings actions.
- The `Advanced` submenu includes a `Latest snapshot` item that reveals the windows captured in the most recent snapshot so the user can inspect what Stay believes it saved.
- Menu-bar messaging and controls stay consistent with the real runtime state, especially around separate-spaces pause mode, launch-at-login state, snapshot availability, and restore availability.

## Exit criteria

- The installed app defaults to launch at login, but opting out remains easy and explicit in the menu.
- The menu-bar presentation uses an icon-led design with a clear primary surface and an `Advanced` submenu for manual tools.
- The menu shows an explicit `ready` versus `paused` state, including when Stay is paused because `Displays have separate Spaces` is enabled.
- The latest captured snapshot can be inspected from the menu without needing logs or filesystem access.
- Any new UX behavior is covered by focused automated tests where practical and documented in the product docs.
- The polish changes do not regress the existing bundle, launch-at-login, pause-mode, or restore behavior.

## Promotion rule

- Promote this plan once the installed app has a coherent default startup behavior, icon-based menu-bar presence, and structured advanced controls, so remaining UX work is incremental rather than foundational.
