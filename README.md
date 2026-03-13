# Stay

Stay is a lightweight macOS utility that records app window layouts before sleep and restores them when the Mac wakes.

## Current Scope (v0)

- Menu bar utility (no dock app window)
- Captures movable app windows using macOS Accessibility APIs
- Persists snapshots to `~/Library/Application Support/Stay/window-layout.json`
- Restores windows after wake only after required displays are online and awake (with timeout fallback)
- Includes unit tests for repeated/out-of-order sleep and wake events
- Includes integration tests for sleep/wake restore flows

## Requirements

- macOS Tahoe (26.0) or newer
- Accessibility permission enabled for Stay

## Run

```bash
swift run Stay
```

## Build A Bundle

```bash
./Scripts/build-stay-app.sh
```

This stages a launchable `Stay.app` bundle at `dist/Stay.app`.
If a `Developer ID Application` signing identity is available locally, the script uses it automatically.
Otherwise it falls back to `Apple Development`, and only then to ad-hoc signing.
When using `Developer ID Application`, the bundle is signed with hardened runtime so it is notarization-ready.
The default distribution bundle identifier is `net.mattclark.stay`.

## Install

```bash
./Scripts/install-stay-app.sh
```

By default this installs `Stay.app` into `/Applications`.

Launch it normally with:

```bash
open /Applications/Stay.app
```

## Notarize

Store credentials once:

```bash
./Scripts/store-notary-credentials.sh StayNotary
```

Then notarize and staple the app bundle:

```bash
NOTARY_PROFILE=StayNotary ./Scripts/notarize-stay-app.sh
```

## Test

```bash
swift test
```
