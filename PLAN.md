# Plan: Awake-Time Disconnect And Reconnect Of The Same Display

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by handling the next awake-time topology case after stale-target invalidation: the same display disappears and later comes back while Stay is still running.

## Objective

- Prove the smallest correct reconnect behavior first so that when the same display returns while Stay is awake, windows that belonged on it end up back on that display instead of remaining stranded on the fallback display set.

## Scenario mapping

- A window is saved on a secondary display, that display disconnects while Stay is awake, and the same display reconnects later; Stay restores the window to its original display placement once that display is available again.
- The baseline invalidation work already completed remains intact: if the display never comes back, stale targets stay invalidated and later restores do not use them.
- Sleep/wake topology ambiguity and replacement-display behavior remain out of scope for this plan and stay on later roadmap items.

## Exit criteria

- Stay can distinguish "same display came back while awake" from "display is still absent" well enough to restore windows to their original display once it reconnects.
- The reconnect behavior has deterministic automated coverage before production changes are promoted.
- The existing awake-time invalidation baseline remains green and documented.
- Relevant docs describe the boundary between awake-time reconnect, sleep/wake ambiguity, and replacement-display behavior.

## Promotion rule

- Promote this plan only after the reconnect behavior is automated on top of the existing invalidation baseline; if reconnect identification proves unreliable, stop at the invalidation behavior and capture the gap explicitly.
