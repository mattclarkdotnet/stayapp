#!/bin/zsh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
APP_NAME="Stay.app"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist}"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME"
INFO_PLIST_SOURCE="$ROOT_DIR/AppBundle/Info.plist"

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
  /usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null
fi

echo "Built $APP_BUNDLE"
