#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
APP_NAME="Stay.app"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist}"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME"
INFO_PLIST_SOURCE="$ROOT_DIR/AppBundle/Info.plist"
SIGNING_IDENTITY=${SIGNING_IDENTITY:-}

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
  echo "Missing Info.plist template at $INFO_PLIST_SOURCE" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"

swift build -c "$CONFIGURATION" --product Stay
BIN_PATH=$(swift build -c "$CONFIGURATION" --show-bin-path)
EXECUTABLE="$BIN_PATH/Stay"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Expected Stay executable at $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

/usr/bin/ditto "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Stay"
/usr/bin/ditto "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -F'"' '/Developer ID Application:/ { print $2; exit }'
    )
  fi

  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY=$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk -F'"' '/Apple Development:/ { print $2; exit }'
    )
  fi

  CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --timestamp=none)
  if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
    CODESIGN_ARGS=(--force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
  fi

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    /usr/bin/codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE" >/dev/null
    echo "Signed with $SIGNING_IDENTITY"
  else
    /usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
    echo "Signed ad hoc (no Apple Development identity found)"
  fi
fi

echo "Built $APP_BUNDLE"
