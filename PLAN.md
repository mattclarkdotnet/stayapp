# Plan: Bundling And Installability

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by turning Stay into a normal installable macOS app bundle before login-item and distribution work build on top of it.

## Objective

- Land the smallest useful bundling/installability slice that lets Stay be built, installed, and launched as a recognizable app bundle without changing its validated restore behavior.

## Assumptions

- Bundling/installability comes before login-item work so startup registration can target a stable app bundle identity.
- The first slice does not need to solve signing, notarization, TestFlight, or App Store submission yet.
- App icon and bundle metadata are in scope here if they are necessary to make the bundle installable and understandable in Finder/System Settings.

## Scenario mapping

- Stay can be built into a normal app bundle and launched from that bundle while preserving its current menu-bar-only behavior.
- Stay can be installed into a conventional location and relaunched later without depending on the transient SwiftPM build path.
- The bundled app has enough metadata and assets that macOS surfaces it as a coherent app rather than an anonymous development artifact.

## Exit criteria

- Stay runs correctly from an installable app bundle.
- The bundling approach is documented clearly enough for the later login-item and distribution roadmap items to build on it.
- Existing focused restore verification remains green after the bundling changes.

## Promotion rule

- Promote this plan only after the bundle/install flow works end-to-end; if signing or distribution concerns start to dominate, defer them and move on to the separate login-item roadmap item.
