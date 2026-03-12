# Plan: Monitor Configuration Changes Between Sleep And Wake

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by handling the ambiguous case where the display set seen after wake does not match the set captured before sleep.

## Objective

- Keep post-wake behavior safe when monitor topology appears to change during sleep, preferring no unexpected movement over speculative restores to the wrong display.

## Scenario mapping

- A display that held saved windows before sleep is missing immediately after wake; Stay should not crash and should avoid moving windows onto an unrelated display just because readiness is incomplete.
- A display appears late enough after wake that the early post-wake topology looks incomplete; Stay should tolerate that ambiguity without permanently invalidating the original target too soon.
- Awake-time topology handling stays as already shipped: real disconnects while the system is awake still invalidate or reactivate snapshots immediately, and replacement-display behavior remains out of scope for this plan.

## Exit criteria

- Sleep/wake restore remains stable when the post-wake display set is temporarily incomplete or genuinely changed.
- No existing awake-time invalidation or reconnect behavior regresses while this plan is implemented.
- The resulting behavior and boundaries are documented clearly enough that replacement-display follow-up work can build on them without re-opening this plan.

## Promotion rule

- Promote this plan only after post-wake behavior is proven safe under ambiguous topology changes; if reliable distinction is not feasible, keep the implementation conservative and record the remaining gap explicitly.
