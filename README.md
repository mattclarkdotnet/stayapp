# Stay

Stay is a lightweight macOS utility that records app window layouts before sleep and restores them when the Mac wakes.

## Current Scope (v0)

- Menu bar utility (no dock app window)
- Captures movable app windows using macOS Accessibility APIs
- Persists snapshots to `~/Library/Application Support/Stay/window-layout.json`
- Restores windows after wake only after required displays are online and awake (with timeout fallback)
- Includes unit tests for repeated/out-of-order sleep and wake events

## Requirements

- macOS Tahoe (26.0) or newer
- Accessibility permission enabled for Stay

## Run

```bash
swift run Stay
```

## Test

```bash
swift test
```
