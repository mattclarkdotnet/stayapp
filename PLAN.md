# Plan: Monitor Configuration Changes While Awake

## Roadmap alignment

- This plan implements `ROADMAP.md` `Now` by handling the simpler topology-change case first: displays that are added or removed while Stay is already awake.

## Objective

- Prove the smallest safe awake-time behavior first by invalidating saved snapshot entries for displays that disappear while Stay is running, so later restore attempts cannot use stale placement targets.

## Scenario mapping

- A snapshot set contains windows assigned to two displays, then one display disconnects while Stay is awake; snapshot entries targeting the missing display are invalidated before the next restore attempt.
- A new capture after an awake-time topology change only produces restorable snapshots for displays that are currently present.
- Awake-time reconnect of the same display and sleep-time topology changes both remain out of scope for this plan and are handled by later roadmap items.

## Exit criteria

- Stay invalidates snapshot entries for displays that disappear while the app is awake.
- Later restore attempts do not move windows using stale targets from removed displays.
- Deterministic automated coverage exists for the awake-time invalidation behavior before production changes are promoted.
- Relevant docs describe the difference between awake-time invalidation, awake-time reconnect, and sleep/wake topology changes.

## Promotion rule

- Promote this plan only after awake-time invalidation behavior is automated first; only then move to the separate sleep/wake roadmap item where missing displays may be temporary.
